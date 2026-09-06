#!/usr/bin/env python3

from __future__ import annotations

import getpass
import json
import os
import re
import shutil
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
BASE_URL_RE = re.compile(r"^\s*base_url\s*=")
USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
TOKEN_URL = "https://auth.openai.com/oauth/token"
OAUTH_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
ACCOUNT_QUERY_INTERVAL_SECONDS = 1


class UserError(Exception):
    pass


class AuthExpiredError(UserError):
    pass


class AuthManager:
    def __init__(self) -> None:
        self.root = Path(__file__).resolve().parent
        self.auth = self.root / "auth.json"
        self.auth_hub = self.root / "auth.json.hub"
        self.hub_config = self.root / "hub_config.json"
        self.account_usage = self.root / "account_usage.json"
        self.config = self.root / "config.toml"
        self.config_account = self.root / "config.toml.account"
        self.config_hub = self.root / "config.toml.hub"
        self.marker = self.root / ".active-auth-profile"
        self.legacy_marker = self.root / ".active-account"
        self.lock = self.root / ".auth-switch.lock"

    @staticmethod
    def validate_name(name: str) -> None:
        if not NAME_RE.fullmatch(name):
            raise UserError("名称只能包含字母、数字、下划线和连字符。")

    @staticmethod
    def type_label(profile_type: str) -> str:
        return "账号" if profile_type == "account" else "中转站"

    @staticmethod
    def require_regular(path: Path, label: str) -> None:
        if path.is_symlink() or not path.is_file():
            raise UserError(f"找不到普通文件：{label}（{path}）")

    def account_file(self, name: str) -> Path:
        return self.root / f"auth.json.{name}"

    def read_current(self) -> tuple[str, str] | None:
        if self.marker.is_symlink():
            raise UserError(f"活动标记不能是符号链接：{self.marker}")
        if self.marker.is_file():
            parts = self.marker.read_text(encoding="utf-8").strip().split()
            if len(parts) != 2 or parts[0] not in {"account", "hub"}:
                raise UserError(f"活动标记格式无效：{self.marker}")
            self.validate_name(parts[1])
            return parts[0], parts[1]

        if self.legacy_marker.is_symlink():
            raise UserError(f"旧账号标记不能是符号链接：{self.legacy_marker}")
        if self.legacy_marker.is_file():
            name = self.legacy_marker.read_text(encoding="utf-8").strip()
            self.validate_name(name)
            return "account", name
        return None

    @staticmethod
    def read_json(path: Path, label: str) -> dict:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise UserError(f"{label} 不是有效 JSON：{path}") from exc
        if not isinstance(data, dict):
            raise UserError(f"{label} 顶层必须是 JSON 对象：{path}")
        return data

    def read_hubs(self) -> dict[str, dict[str, str]]:
        if self.hub_config.is_symlink():
            raise UserError(f"中转站配置不能是符号链接：{self.hub_config}")
        if not self.hub_config.exists():
            return {}

        try:
            raw_config = self.hub_config.read_text(encoding="utf-8")
        except OSError as exc:
            raise UserError(f"无法读取中转站配置：{self.hub_config}") from exc
        if not raw_config.strip():
            return {}
        try:
            data = json.loads(raw_config)
        except json.JSONDecodeError as exc:
            raise UserError(f"中转站配置不是有效 JSON：{self.hub_config}") from exc
        if not isinstance(data, dict):
            raise UserError(f"中转站配置顶层必须是 JSON 对象：{self.hub_config}")
        for name, value in data.items():
            self.validate_name(name)
            if not isinstance(value, dict):
                raise UserError(f"中转站 {name} 的配置必须是 JSON 对象。")
            if set(value) != {"base_url", "api_key"}:
                raise UserError(f"中转站 {name} 必须且只能包含 base_url 和 api_key。")
            if not isinstance(value["base_url"], str) or not isinstance(value["api_key"], str):
                raise UserError(f"中转站 {name} 的 base_url 和 api_key 必须是字符串。")
        return data

    def read_account_usage(self) -> dict[str, dict[str, object]]:
        if self.account_usage.is_symlink():
            raise UserError(f"账号限额文件不能是符号链接：{self.account_usage}")
        if not self.account_usage.exists():
            return {}
        try:
            raw = self.account_usage.read_text(encoding="utf-8")
        except OSError as exc:
            raise UserError(f"无法读取账号限额文件：{self.account_usage}") from exc
        if not raw.strip():
            return {}
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise UserError(f"账号限额文件不是有效 JSON：{self.account_usage}") from exc
        if not isinstance(data, dict):
            raise UserError(f"账号限额文件顶层必须是 JSON 对象：{self.account_usage}")

        required = {
            "five_hour_remaining",
            "five_hour_reset",
            "weekly_remaining",
            "weekly_reset",
            "noted_at",
        }
        for account, value in data.items():
            self.validate_name(account)
            if (
                not isinstance(value, dict)
                or not required.issubset(value)
                or not set(value).issubset(required | {"reset_cards", "credit_balance", "weekly_reset_at", "auth_invalid"})
            ):
                raise UserError(f"账号 {account} 的限额记录格式无效。")
            self.validate_quota(value["five_hour_remaining"], "5小时额度")
            self.validate_reset_time(value["five_hour_reset"])
            self.validate_quota(value["weekly_remaining"], "周额度")
            self.validate_weekly_reset(value["weekly_reset"])
            if not isinstance(value["noted_at"], str):
                raise UserError(f"账号 {account} 的记录时间格式无效。")
            self.validate_reset_cards(value.get("reset_cards", 0))
            if not isinstance(value.get("auth_invalid", False), bool):
                raise UserError(f"账号 {account} 的登录状态格式无效。")
            value.setdefault("reset_cards", 0)
            value.setdefault("auth_invalid", False)
        return data

    @staticmethod
    def validate_quota(value: object, label: str) -> int:
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 100:
            raise UserError(f"{label}必须是0到100之间的整数。")
        return value

    @staticmethod
    def validate_reset_cards(value: object) -> int:
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise UserError("重置卡数量必须是大于或等于0的整数。")
        return value

    @staticmethod
    def validate_reset_time(value: object) -> str:
        if not isinstance(value, str):
            raise UserError("5小时重置时间格式无效。")
        value = value.strip()

        time_only = re.fullmatch(r"([01]?\d|2[0-3]):([0-5]\d)", value)
        if time_only:
            hour, minute = (int(part) for part in time_only.groups())
            return f"{hour:02d}:{minute:02d}"

        month_day = re.fullmatch(
            r"(\d{1,2})\.(\d{1,2})\s+([01]?\d|2[0-3]):([0-5]\d)", value
        )
        if month_day:
            month, day, hour, minute = (int(part) for part in month_day.groups())
            try:
                datetime(2000, month, day, hour, minute)
            except ValueError as exc:
                raise UserError("5小时重置时间包含无效日期。") from exc
            return f"{month}.{day} {hour:02d}:{minute:02d}"

        full_date = re.fullmatch(
            r"(\d{4})-(\d{2})-(\d{2})\s+([01]\d|2[0-3]):([0-5]\d)", value
        )
        if full_date:
            year, month, day, hour, minute = (int(part) for part in full_date.groups())
            try:
                datetime(year, month, day, hour, minute)
            except ValueError as exc:
                raise UserError("5小时重置时间包含无效日期。") from exc
            return f"{year:04d}-{month:02d}-{day:02d} {hour:02d}:{minute:02d}"

        raise UserError(
            "5小时重置时间应使用 HH:MM、M.D HH:MM 或 YYYY-MM-DD HH:MM。"
        )

    @staticmethod
    def reset_datetime(value: str, now: datetime) -> datetime:
        normalized = AuthManager.validate_reset_time(value)
        if re.fullmatch(r"\d{2}:\d{2}", normalized):
            hour, minute = (int(part) for part in normalized.split(":"))
            return now.replace(hour=hour, minute=minute, second=0, microsecond=0)

        if re.fullmatch(r"\d{1,2}\.\d{1,2} \d{2}:\d{2}", normalized):
            date_part, time_part = normalized.split()
            month, day = (int(part) for part in date_part.split("."))
            hour, minute = (int(part) for part in time_part.split(":"))
            try:
                return datetime(
                    now.year, month, day, hour, minute, tzinfo=now.tzinfo
                )
            except ValueError as exc:
                raise UserError(
                    "今年没有该日期；请使用 YYYY-MM-DD HH:MM 明确指定年份。"
                ) from exc

        parsed = datetime.strptime(normalized, "%Y-%m-%d %H:%M")
        return parsed.replace(tzinfo=now.tzinfo)

    @staticmethod
    def validate_weekly_reset(value: object) -> str:
        if not isinstance(value, str):
            raise UserError("周额度重置日期必须使用 M.D，例如 9.12。")
        match = re.fullmatch(r"(\d{1,2})\.(\d{1,2})", value)
        if not match:
            raise UserError("周额度重置日期必须使用 M.D，例如 9.12。")
        month, day = (int(part) for part in match.groups())
        try:
            datetime(2000, month, day)
        except ValueError as exc:
            raise UserError("周额度重置日期不是有效日期。") from exc
        return f"{month}.{day}"

    def account_is_known(self, name: str) -> bool:
        current = self.read_current()
        account_file = self.account_file(name)
        return (
            account_file.is_file() and not account_file.is_symlink()
        ) or current == ("account", name)

    def account_auth_files(self) -> dict[str, Path]:
        result: dict[str, Path] = {}
        current = self.read_current()
        if current and current[0] == "account":
            self.require_regular(self.auth, "活动账号认证文件")
            result[current[1]] = self.auth
        for path in self.root.glob("auth.json.*"):
            suffix = path.name.removeprefix("auth.json.")
            if (
                path.is_file()
                and not path.is_symlink()
                and suffix not in {"bak", "hub"}
                and not suffix.startswith("hub.")
                and NAME_RE.fullmatch(suffix)
            ):
                result[suffix] = path
        return dict(sorted(result.items()))

    @staticmethod
    def request_json(url: str, headers: dict[str, str], body: dict | None = None) -> dict:
        encoded = None
        if body is not None:
            encoded = json.dumps(body).encode("utf-8")
            headers = {**headers, "Content-Type": "application/json"}
        try:
            with urlopen(Request(url, data=encoded, headers=headers), timeout=20) as response:
                value = json.load(response)
        except HTTPError:
            raise
        except (OSError, URLError, json.JSONDecodeError) as exc:
            raise UserError(f"连接 OpenAI 用量服务失败：{exc}") from exc
        if not isinstance(value, dict):
            raise UserError("OpenAI 用量服务返回了无法识别的数据。")
        return value

    def refresh_access_token(self, path: Path, auth_data: dict) -> dict:
        tokens = auth_data.get("tokens")
        refresh_token = tokens.get("refresh_token") if isinstance(tokens, dict) else None
        if not isinstance(refresh_token, str) or not refresh_token:
            raise AuthExpiredError("登录令牌已失效且没有可用的刷新令牌，请切换到该账号重新登录。")
        try:
            refreshed = self.request_json(
                TOKEN_URL,
                {},
                {
                    "client_id": OAUTH_CLIENT_ID,
                    "grant_type": "refresh_token",
                    "refresh_token": refresh_token,
                },
            )
        except HTTPError as exc:
            raise AuthExpiredError(
                f"登录令牌刷新失败（HTTP {exc.code}），请切换到该账号重新登录。"
            ) from exc
        for key in ("id_token", "access_token", "refresh_token"):
            value = refreshed.get(key)
            if isinstance(value, str) and value:
                tokens[key] = value
        if not isinstance(tokens.get("access_token"), str) or not tokens["access_token"]:
            raise UserError("OpenAI 没有返回可用的登录令牌。")
        auth_data["last_refresh"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        self.atomic_write_json(path, auth_data)
        return auth_data

    def fetch_account_usage(self, path: Path) -> dict[str, object]:
        auth_data = self.read_json(path, "账号认证文件")
        tokens = auth_data.get("tokens")
        if not isinstance(tokens, dict):
            raise UserError("账号认证文件不包含登录令牌。")

        def fetch(data: dict) -> dict:
            current_tokens = data.get("tokens")
            access_token = current_tokens.get("access_token") if isinstance(current_tokens, dict) else None
            account_id = current_tokens.get("account_id") if isinstance(current_tokens, dict) else None
            if not isinstance(access_token, str) or not access_token:
                raise UserError("账号认证文件缺少 access_token。")
            headers = {
                "Authorization": f"Bearer {access_token}",
                "User-Agent": "switch-account.sh",
            }
            if isinstance(account_id, str) and account_id:
                headers["ChatGPT-Account-Id"] = account_id
            return self.request_json(USAGE_URL, headers)

        try:
            response = fetch(auth_data)
        except HTTPError as exc:
            if exc.code != 401:
                raise UserError(f"查询用量失败（HTTP {exc.code}）。") from exc
            auth_data = self.refresh_access_token(path, auth_data)
            try:
                response = fetch(auth_data)
            except HTTPError as retry_exc:
                if retry_exc.code == 401:
                    raise AuthExpiredError("登录令牌已失效，请切换到该账号重新登录。") from retry_exc
                raise UserError(f"刷新登录令牌后查询仍失败（HTTP {retry_exc.code}）。") from retry_exc

        rate_limit = response.get("rate_limit")
        if not isinstance(rate_limit, dict):
            raise UserError("用量结果缺少 rate_limit。")
        primary = rate_limit.get("primary_window")
        secondary = rate_limit.get("secondary_window")
        if not isinstance(primary, dict) or not isinstance(secondary, dict):
            raise UserError("用量结果缺少5小时或周窗口。")

        def remaining(window: dict, label: str) -> int:
            used = window.get("used_percent")
            if isinstance(used, bool) or not isinstance(used, (int, float)):
                raise UserError(f"用量结果中的{label}比例无效。")
            return max(0, min(100, int(round(100 - used))))

        def reset_at(window: dict, label: str) -> datetime:
            value = window.get("reset_at")
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise UserError(f"用量结果中的{label}重置时间无效。")
            return datetime.fromtimestamp(value, tz=timezone.utc).astimezone()

        credits = response.get("rate_limit_reset_credits")
        reset_cards = credits.get("available_count", 0) if isinstance(credits, dict) else 0
        if isinstance(reset_cards, bool) or not isinstance(reset_cards, int) or reset_cards < 0:
            reset_cards = 0
        credit_info = response.get("credits")
        credit_balance = credit_info.get("balance") if isinstance(credit_info, dict) else None
        try:
            credit_balance = float(credit_balance) if credit_balance is not None else None
        except (TypeError, ValueError):
            credit_balance = None
        five_reset = reset_at(primary, "5小时")
        weekly_reset = reset_at(secondary, "周")
        return {
            "five_hour_remaining": remaining(primary, "5小时"),
            "five_hour_reset": five_reset.strftime("%Y-%m-%d %H:%M"),
            "weekly_remaining": remaining(secondary, "周"),
            "weekly_reset": f"{weekly_reset.month}.{weekly_reset.day}",
            "weekly_reset_at": weekly_reset.isoformat(timespec="seconds"),
            "reset_cards": reset_cards,
            "credit_balance": credit_balance,
            "auth_invalid": False,
            "noted_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        }

    def refresh_usage(
        self, verbose: bool = True, requested_account: str | None = None, skip_invalid: bool = False
    ) -> tuple[int, list[str]]:
        files = self.account_auth_files()
        if requested_account is not None:
            self.validate_name(requested_account)
            path = files.get(requested_account)
            if path is None:
                raise UserError(f"找不到账号：{requested_account}")
            files = {requested_account: path}
        if not files:
            raise UserError("没有找到可查询的账号认证文件。")
        usage = self.read_account_usage()
        if skip_invalid and requested_account is None:
            files = {name: path for name, path in files.items() if not usage.get(name, {}).get("auth_invalid", False)}
            if not files:
                return 0, []
        failures: list[str] = []
        refreshed = 0
        self.acquire_lock()
        try:
            items = list(files.items())
            for index, (account, path) in enumerate(items):
                try:
                    usage[account] = self.fetch_account_usage(path)
                    refreshed += 1
                    if verbose:
                        print(f"已刷新：{account}")
                except AuthExpiredError as exc:
                    now = datetime.now().astimezone()
                    record = usage.setdefault(account, {
                        "five_hour_remaining": 0,
                        "five_hour_reset": now.strftime("%Y-%m-%d %H:%M"),
                        "weekly_remaining": 0,
                        "weekly_reset": f"{now.month}.{now.day}",
                        "weekly_reset_at": None,
                        "reset_cards": 0,
                        "credit_balance": None,
                        "noted_at": now.isoformat(timespec="seconds"),
                    })
                    record["auth_invalid"] = True
                    failures.append(f"{account}：{exc}")
                except UserError as exc:
                    failures.append(f"{account}：{exc}")
                if index < len(items) - 1:
                    print(
                        f"等待 {ACCOUNT_QUERY_INTERVAL_SECONDS} 秒后查询下一个账号……",
                        file=sys.stderr,
                    )
                    time.sleep(ACCOUNT_QUERY_INTERVAL_SECONDS)
            if refreshed or any(record.get("auth_invalid") for record in usage.values()):
                self.atomic_write_json(self.account_usage, usage)
        finally:
            self.release_lock()
        for failure in failures:
            print(f"警告：{failure}", file=sys.stderr)
        if not refreshed and failures:
            raise UserError("所有账号的用量查询都失败了。")
        return refreshed, failures

    def note_account(self, requested_name: str | None) -> None:
        if requested_name is None:
            current = self.read_current()
            if current is None or current[0] != "account":
                raise UserError("当前不是账号，请指定账号名：note <账号名>")
            account = current[1]
        else:
            account = requested_name
            self.validate_name(account)

        if not self.account_is_known(account):
            raise UserError(f"找不到账号：{account}")

        five_hour_remaining = self.read_quota_input("5小时剩余额度（0-100）: ", "5小时额度")
        five_hour_reset = self.read_text_input(
            "5小时重置时间（HH:MM、M.D HH:MM 或 YYYY-MM-DD HH:MM）: "
        )
        five_hour_reset = self.validate_reset_time(five_hour_reset)
        weekly_remaining = self.read_quota_input("周剩余额度（0-100）: ", "周额度")

        now = datetime.now().astimezone()
        reset_at = self.reset_datetime(five_hour_reset, now)
        if five_hour_remaining == 0 and weekly_remaining > 0 and reset_at <= now:
            raise UserError(
                "5小时重置时间已经过去，5小时额度应已重置为非0。"
                "请填写当前额度；只有周额度为0时才允许继续记录为0。"
            )

        weekly_reset = self.read_text_input("周额度重置日期（M.D）: ")
        weekly_reset = self.validate_weekly_reset(weekly_reset)
        reset_cards = self.read_reset_cards_input()

        usage = self.read_account_usage()
        usage[account] = {
            "five_hour_remaining": five_hour_remaining,
            "five_hour_reset": five_hour_reset,
            "weekly_remaining": weekly_remaining,
            "weekly_reset": weekly_reset,
            "reset_cards": reset_cards,
            "noted_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        }
        self.atomic_write_json(self.account_usage, usage)
        print(f"已记录账号限额：{account}")

    @staticmethod
    def read_text_input(prompt: str) -> str:
        try:
            value = input(prompt).strip()
        except EOFError as exc:
            raise UserError(f"没有读到输入：{prompt.strip()}") from exc
        if not value:
            raise UserError(f"输入不能为空：{prompt.strip()}")
        return value

    def read_quota_input(self, prompt: str, label: str) -> int:
        raw = self.read_text_input(prompt)
        if not raw.isdigit():
            raise UserError(f"{label}必须是0到100之间的整数。")
        return self.validate_quota(int(raw), label)

    def read_reset_cards_input(self) -> int:
        try:
            raw = input("重置卡数量（直接回车默认为0）: ").strip()
        except EOFError:
            return 0
        if not raw:
            return 0
        if not raw.isdigit():
            raise UserError("重置卡数量必须是大于或等于0的整数。")
        return self.validate_reset_cards(int(raw))

    def select_next_account(
        self, usage: dict[str, dict[str, object]]
    ) -> tuple[str, dict[str, object]] | None:
        candidates: list[tuple[timedelta, str]] = []
        now = datetime.now().astimezone()
        current = self.read_current()

        for account, record in usage.items():
            if not self.account_is_known(account):
                continue
            if current == ("account", account):
                continue
            if record["weekly_remaining"] <= 0 or record["five_hour_remaining"] <= 0:
                continue
            reset = self.reset_datetime(str(record["five_hour_reset"]), now)
            if reset < now:
                continue
            candidates.append((reset - now, account))

        if candidates:
            candidates.sort(key=lambda item: (item[0], item[1]))
            account = candidates[0][1]
            return account, usage[account]
        return None

    def reset_card_accounts(
        self, usage: dict[str, dict[str, object]]
    ) -> list[tuple[str, int]]:
        current = self.read_current()
        result: list[tuple[str, int]] = []
        for account, record in usage.items():
            if not self.account_is_known(account) or current == ("account", account):
                continue
            count = int(record.get("reset_cards", 0))
            if count > 0:
                result.append((account, count))
        return sorted(result)

    @staticmethod
    def print_account_usage(account: str, record: dict[str, object]) -> None:
        print(f"账号：{account}")
        print(f"5小时剩余额度：{record['five_hour_remaining']}%")
        print(f"5小时重置时间：{record['five_hour_reset']}")
        print(f"周剩余额度：{record['weekly_remaining']}%")
        print(f"周额度重置日期：{record['weekly_reset']}")
        print(f"重置卡：{record.get('reset_cards', 0)}张")

    def next_account(self) -> None:
        self.refresh_usage(verbose=False)
        usage = self.read_account_usage()
        selected = self.select_next_account(usage)
        if selected:
            self.print_account_usage(*selected)
            return
        reset_card_accounts = self.reset_card_accounts(usage)
        if reset_card_accounts:
            print("没有同时具备周额度和5小时额度的账号。以下账号有重置卡：")
            for account, count in reset_card_accounts:
                print(f"  {account}（{count}张）")
            return
        raise UserError("没有同时具备周额度和5小时额度的账号，也没有记录到重置卡。")

    def switch_next_account(self) -> None:
        self.refresh_usage(verbose=False)
        usage = self.read_account_usage()
        selected = self.select_next_account(usage)
        if selected is None:
            reset_cards = self.reset_card_accounts(usage)
            if reset_cards:
                names = "、".join(f"{name}（{count}张）" for name, count in reset_cards)
                raise UserError(f"没有符合额度条件的账号；有重置卡的账号：{names}")
            raise UserError("没有符合额度条件的账号，也没有记录到重置卡。")
        account, _ = selected
        self.switch_account(account)

    @staticmethod
    def validate_base_url(base_url: str) -> None:
        parsed = urlparse(base_url)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.netloc
            or any(char.isspace() for char in base_url)
        ):
            raise UserError("base_url 必须是完整的 http:// 或 https:// 地址，且不能包含空格。")

    @staticmethod
    def atomic_write(path: Path, content: bytes, mode: int | None = None) -> None:
        if path.is_symlink():
            raise UserError(f"拒绝覆盖符号链接：{path}")
        if mode is None:
            mode = (path.stat().st_mode & 0o777) if path.exists() else 0o600

        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.tmp.", dir=path.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, mode)
            os.replace(temporary, path)
        finally:
            if temporary.exists():
                temporary.unlink()

    def atomic_write_json(self, path: Path, data: dict) -> None:
        content = (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        self.atomic_write(path, content, 0o600)

    def write_marker(self, profile_type: str, name: str) -> None:
        self.atomic_write(self.marker, f"{profile_type} {name}\n".encode(), 0o600)

    @staticmethod
    def snapshots(paths: list[Path]) -> dict[Path, tuple[bytes, int] | None]:
        result: dict[Path, tuple[bytes, int] | None] = {}
        for path in paths:
            if path.is_symlink():
                raise UserError(f"拒绝处理符号链接：{path}")
            if path.exists():
                result[path] = (path.read_bytes(), path.stat().st_mode & 0o777)
            else:
                result[path] = None
        return result

    def restore(self, snapshots: dict[Path, tuple[bytes, int] | None]) -> None:
        for path, snapshot in snapshots.items():
            if snapshot is None:
                if path.exists() and not path.is_symlink():
                    path.unlink()
            else:
                content, mode = snapshot
                self.atomic_write(path, content, mode)

    def acquire_lock(self) -> None:
        try:
            self.lock.mkdir(mode=0o700)
        except FileExistsError as exc:
            raise UserError(f"另一个切换操作可能正在进行：{self.lock}") from exc

    def release_lock(self) -> None:
        try:
            self.lock.rmdir()
        except FileNotFoundError:
            pass

    def ensure_hub_template(self) -> dict:
        if not self.auth_hub.exists():
            template = {"OPENAI_API_KEY": ""}
            self.atomic_write_json(self.auth_hub, template)
            return template

        self.require_regular(self.auth_hub, "中转站认证模板")
        if self.auth_hub.stat().st_size == 0:
            template = {"OPENAI_API_KEY": ""}
            self.atomic_write_json(self.auth_hub, template)
            return template
        template = self.read_json(self.auth_hub, "中转站认证模板")
        if "OPENAI_API_KEY" not in template or not isinstance(template["OPENAI_API_KEY"], str):
            raise UserError("auth.json.hub 必须包含字符串字段 OPENAI_API_KEY。")
        return template

    def validate_account_config(self, path: Path) -> None:
        self.require_regular(path, "账号配置")
        content = path.read_text(encoding="utf-8")
        if re.search(r"(?m)^\s*(?:provider|model_provider)\s*=", content):
            raise UserError(f"账号配置不应包含 provider 或 model_provider：{path}")
        if re.search(r"(?m)^\s*\[model_providers\.", content):
            raise UserError(f"账号配置不应包含 model_providers 配置段：{path}")

    def validate_hub_config_file(self, path: Path) -> None:
        self.require_regular(path, "中转站 TOML 配置")
        content = path.read_text(encoding="utf-8")
        if not re.search(r'(?m)^\s*provider\s*=\s*"OpenAI"\s*$', content):
            raise UserError(f'中转站配置缺少 provider = "OpenAI"：{path}')
        if not re.search(r"(?m)^\s*\[model_providers\.OpenAI\]\s*$", content):
            raise UserError(f"中转站配置缺少 [model_providers.OpenAI]：{path}")

    def validate_topology(self, profile_type: str) -> None:
        self.require_regular(self.auth, "活动认证文件")
        self.require_regular(self.config, "活动配置文件")
        if profile_type == "account":
            self.validate_account_config(self.config)
            if self.config_account.exists() or self.config_account.is_symlink():
                raise UserError(f"账号活动时不应存在：{self.config_account}")
        else:
            template = self.read_json(self.auth, "活动中转站认证")
            if set(template) != {"OPENAI_API_KEY"}:
                raise UserError("中转站活动时，auth.json 只能包含 OPENAI_API_KEY。")
            self.validate_hub_config_file(self.config)
            self.validate_account_config(self.config_account)
            if self.auth_hub.exists() or self.auth_hub.is_symlink():
                raise UserError(f"中转站活动时不应存在：{self.auth_hub}")
            if self.config_hub.exists() or self.config_hub.is_symlink():
                raise UserError(f"中转站活动时不应存在：{self.config_hub}")

    def add_hub(self, name: str) -> None:
        self.validate_name(name)
        hubs = self.read_hubs()
        if name in hubs:
            raise UserError(f"中转站已存在，为避免覆盖已停止：{name}")

        try:
            base_url = input("base_url: ").strip()
        except EOFError as exc:
            raise UserError("没有读到 base_url。") from exc
        self.validate_base_url(base_url)

        if sys.stdin.isatty():
            api_key = getpass.getpass("api_key: ")
        else:
            print("api_key: ", end="", file=sys.stderr, flush=True)
            api_key = sys.stdin.readline().rstrip("\r\n")
        if not api_key:
            raise UserError("api_key 不能为空。")

        hubs[name] = {"base_url": base_url, "api_key": api_key}
        self.atomic_write_json(self.hub_config, hubs)
        print(f"已添加中转站：{name}")

    def render_hub_files(
        self, name: str, auth_source: Path, config_source: Path
    ) -> tuple[bytes, bytes]:
        hubs = self.read_hubs()
        if name not in hubs:
            raise UserError(f"中转站不存在：{name}。请先运行 hub add {name}")
        entry = hubs[name]
        self.validate_base_url(entry["base_url"])
        if not entry["api_key"]:
            raise UserError(f"中转站 {name} 的 api_key 为空。")

        self.require_regular(auth_source, "中转站认证文件")
        if auth_source.stat().st_size == 0:
            template = {"OPENAI_API_KEY": ""}
        else:
            template = self.read_json(auth_source, "中转站认证文件")
        if set(template) != {"OPENAI_API_KEY"}:
            raise UserError("中转站认证文件只能包含 OPENAI_API_KEY，避免混入账号 token。")
        template["OPENAI_API_KEY"] = entry["api_key"]
        auth_content = (json.dumps(template, ensure_ascii=False, indent=2) + "\n").encode()

        self.validate_hub_config_file(config_source)
        lines = config_source.read_text(encoding="utf-8").splitlines(keepends=True)
        matching = [index for index, line in enumerate(lines) if BASE_URL_RE.match(line)]
        if len(matching) != 1:
            raise UserError("config.toml.hub 必须且只能包含一条 base_url。")
        index = matching[0]
        indent = lines[index][: len(lines[index]) - len(lines[index].lstrip())]
        ending = "\n" if lines[index].endswith("\n") else ""
        lines[index] = f"{indent}base_url = {json.dumps(entry['base_url'])}{ending}"
        return auth_content, "".join(lines).encode("utf-8")

    def register(self, profile_type: str, name: str) -> None:
        self.validate_name(name)
        self.validate_topology(profile_type)
        if profile_type == "hub":
            hubs = self.read_hubs()
            if name not in hubs:
                raise UserError(f"中转站不存在：{name}。请先运行 hub add {name}")
        self.write_marker(profile_type, name)
        print(f"已登记当前{self.type_label(profile_type)}：{name}")

    def show_current(self, requested_type: str) -> None:
        current = self.read_current()
        if current is None:
            raise UserError("未登记。请先运行 register，或运行 hub register。")
        profile_type, name = current
        if profile_type == requested_type:
            print(name)
        else:
            print(
                f"当前启用的是{self.type_label(profile_type)}：{name}；"
                f"没有启用{self.type_label(requested_type)}。"
            )

    def list_profiles(self, requested_type: str) -> None:
        current = self.read_current()
        label = self.type_label(requested_type)
        if current and current[0] == requested_type:
            print(f"当前{label}：{current[1]}")
        else:
            print(f"当前{label}：未启用")
        print(f"可切换{label}：")

        if requested_type == "hub":
            names = sorted(self.read_hubs())
        else:
            names = []
            for path in self.root.glob("auth.json.*"):
                suffix = path.name.removeprefix("auth.json.")
                if (
                    path.is_file()
                    and not path.is_symlink()
                    and suffix != "bak"
                    and suffix != "hub"
                    and not suffix.startswith("hub.")
                    and NAME_RE.fullmatch(suffix)
                ):
                    names.append(suffix)
            names.sort()

        if current and current[0] == requested_type:
            names = [name for name in names if name != current[1]]

        if names:
            for name in names:
                print(f"  {name}")
        else:
            print("  （无）")

    def switch_auto(self, target: str) -> None:
        self.validate_name(target)
        current = self.read_current()
        account_exists = self.account_file(target).is_file()
        if current == ("account", target):
            account_exists = True
        hub_exists = target in self.read_hubs()

        if account_exists and hub_exists:
            raise UserError(
                f"账号和中转站存在同名目标：{target}。"
                f"切换账号请使用 account switch {target}，"
                f"切换中转站请使用 hub switch {target}。"
            )
        if hub_exists:
            self.switch_hub(target)
            return
        if account_exists:
            self.switch_account(target)
            return
        raise UserError(
            f"找不到账号或中转站：{target}。"
            "账号需要 auth.json.<名称>，中转站需要先使用 hub add 添加。"
        )

    def switch_account(self, target: str) -> None:
        self.validate_name(target)
        current = self.read_current()
        if current is None:
            raise UserError("当前配置尚未登记。请先运行 register，或运行 hub register。")
        current_type, current_name = current
        self.validate_topology(current_type)
        if current_type == "account" and current_name == target:
            print(f"当前已经是账号：{target}")
            return

        target_file = self.account_file(target)
        self.require_regular(target_file, "目标账号文件")
        saved_file = self.account_file(current_name) if current_type == "account" else None
        if saved_file and (saved_file.exists() or saved_file.is_symlink()):
            raise UserError(f"为避免覆盖，已停止：{saved_file} 已存在。")
        if current_type == "hub":
            if self.auth_hub.exists() or self.auth_hub.is_symlink():
                raise UserError(f"为避免覆盖，已停止：{self.auth_hub} 已存在。")
            if self.config_hub.exists() or self.config_hub.is_symlink():
                raise UserError(f"为避免覆盖，已停止：{self.config_hub} 已存在。")

        paths = [
            self.auth,
            self.auth_hub,
            target_file,
            self.config,
            self.config_account,
            self.config_hub,
            self.marker,
        ]
        if saved_file:
            paths.append(saved_file)
        before = self.snapshots(paths)
        self.acquire_lock()
        try:
            if current_type == "account":
                assert saved_file is not None
                os.replace(self.auth, saved_file)
                os.replace(target_file, self.auth)
            else:
                os.replace(self.auth, self.auth_hub)
                os.replace(target_file, self.auth)
                os.replace(self.config, self.config_hub)
                os.replace(self.config_account, self.config)
            os.chmod(self.auth, 0o600)
            self.write_marker("account", target)
        except Exception:
            self.restore(before)
            raise
        finally:
            self.release_lock()
        print(
            f"已从{self.type_label(current_type)} {current_name} 切换到账号 {target}。"
            "请完全退出并重新打开 Codex。"
        )

    def switch_hub(self, target: str) -> None:
        self.validate_name(target)
        current = self.read_current()
        if current is None:
            raise UserError("当前配置尚未登记。请先运行 register，或运行 hub register。")
        current_type, current_name = current
        self.validate_topology(current_type)

        if current_type == "account":
            self.require_regular(self.auth_hub, "中转站认证模板")
            self.validate_hub_config_file(self.config_hub)
            if self.config_account.exists() or self.config_account.is_symlink():
                raise UserError(f"为避免覆盖，已停止：{self.config_account} 已存在。")
            auth_source = self.auth_hub
            config_source = self.config_hub
        else:
            auth_source = self.auth
            config_source = self.config

        auth_content, config_content = self.render_hub_files(
            target, auth_source, config_source
        )
        saved_file = self.account_file(current_name) if current_type == "account" else None
        if saved_file and (saved_file.exists() or saved_file.is_symlink()):
            raise UserError(f"为避免覆盖，已停止：{saved_file} 已存在。")

        paths = [
            self.auth,
            self.auth_hub,
            self.config,
            self.config_account,
            self.config_hub,
            self.marker,
        ]
        if saved_file:
            paths.append(saved_file)
        before = self.snapshots(paths)
        self.acquire_lock()
        try:
            if current_type == "account":
                assert saved_file is not None
                self.atomic_write(self.auth_hub, auth_content, 0o600)
                self.atomic_write(self.config_hub, config_content)
                os.replace(self.auth, saved_file)
                os.replace(self.auth_hub, self.auth)
                os.replace(self.config, self.config_account)
                os.replace(self.config_hub, self.config)
            else:
                self.atomic_write(self.auth, auth_content, 0o600)
                self.atomic_write(self.config, config_content)
            os.chmod(self.auth, 0o600)
            self.write_marker("hub", target)
        except Exception:
            self.restore(before)
            raise
        finally:
            self.release_lock()
        print(
            f"已从{self.type_label(current_type)} {current_name} 切换到中转站 {target}。"
            "请完全退出并重新打开 Codex。"
        )


def usage(program: str) -> None:
    print(
f"""通用切换命令（自动识别账号或中转站）：
  {program} switch <目标名称>
  {program} switch next

  switch 可以在账号和中转站之间直接切换。例如：
    当前是账号 vam，执行：{program} switch aihub
    当前是中转站 aihub，执行：{program} switch vam
  switch next 会查询限额并一键切换到下一个可用账号。

账号命令（current、list、register 默认操作账号）：
  {program} current
  {program} list
  {program} refresh
  {program} note [账号名]
  {program} next
  {program} register <当前账号名>
  {program} account switch <目标账号名>

  refresh 根据各账号的 auth.json 自动查询并保存最新限额，账号间隔1秒。
  refresh <账号名> 只查询指定账号，不等待。
  next 会先自动刷新全部账号，再输出下一个账号及其完整限额；当前账号不会入选。
  note 仅作为查询失败时的手动备用；不指定账号名时默认记录当前账号。
  5小时重置时间支持 HH:MM、M.D HH:MM 和 YYYY-MM-DD HH:MM；HH:MM 表示今天，跨天必须写日期。
  5小时额度为0、周额度大于0且重置时间已过去时，note 会停止并提醒额度应已重置。
  note 会记录重置卡数量，直接回车时默认为0。
  next 排除周额度或5小时额度为0的账号，再返回5小时重置时间最近的账号。
  没有符合额度条件的账号时，next 会列出有重置卡的账号。
  自动或手动取得的限额记录保存在 account_usage.json。

中转站命令：
  {program} hub add <中转站名>
  {program} hub current
  {program} hub list
  {program} hub register <当前中转站名>
  {program} hub switch <目标中转站名>

文件规则：
  账号凭据：auth.json.<账号名>
  中转站清单：hub_config.json
  活动认证：auth.json
  非活动中转站认证：auth.json.hub（唯一一份）
  活动配置：config.toml
  非活动账号配置：config.toml.account（所有账号共用）
  非活动中转站配置：config.toml.hub（所有中转站共用）
"""
    )


def main(argv: list[str]) -> int:
    manager = AuthManager()
    program = Path(argv[0]).name
    args = argv[1:]
    profile_type = "account"
    type_explicit = False
    if args and args[0] in {"account", "hub"}:
        profile_type = args[0]
        type_explicit = True
        args = args[1:]

    if not args or args[0] in {"-h", "--help", "help"}:
        usage(program)
        return 0

    command = args[0]
    if profile_type == "hub" and command == "add":
        if len(args) != 2:
            raise UserError(f"用法：{program} hub add <中转站名>")
        manager.add_hub(args[1])
    elif profile_type == "account" and command in {"refresh", "refresh-auto"}:
        if len(args) > 2:
            raise UserError(f"用法：{program} refresh [账号名]")
        refreshed, failures = manager.refresh_usage(
            requested_account=args[1] if len(args) == 2 else None,
            skip_invalid=command == "refresh-auto",
        )
        print(f"刷新完成：成功 {refreshed} 个，失败 {len(failures)} 个。")
    elif profile_type == "account" and command == "note":
        if len(args) > 2:
            raise UserError(f"用法：{program} note [账号名]")
        manager.note_account(args[1] if len(args) == 2 else None)
    elif profile_type == "account" and command == "next":
        if len(args) != 1:
            raise UserError("next 不接受额外参数。")
        manager.next_account()
    elif command == "current":
        if len(args) != 1:
            raise UserError("current 不接受额外参数。")
        manager.show_current(profile_type)
    elif command == "list":
        if len(args) != 1:
            raise UserError("list 不接受额外参数。")
        manager.list_profiles(profile_type)
    elif command == "register":
        if len(args) != 2:
            raise UserError("register 需要一个名称。")
        manager.register(profile_type, args[1])
    elif command == "switch":
        if len(args) != 2:
            raise UserError("switch 需要一个目标名称。")
        if not type_explicit and args[1] == "next":
            manager.switch_next_account()
        elif not type_explicit:
            manager.switch_auto(args[1])
        elif profile_type == "hub":
            manager.switch_hub(args[1])
        else:
            manager.switch_account(args[1])
    else:
        raise UserError(f"未知命令：{command}。请运行 {program} --help")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except UserError as error:
        print(f"错误：{error}", file=sys.stderr)
        raise SystemExit(1)
