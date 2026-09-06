import Foundation

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    static var display: String { "v\(current)" }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .chinese : .english
    }

    var locale: Locale {
        Locale(identifier: resolved() == .chinese ? "zh-Hans" : "en")
    }
}

enum AppLocalization {
    static func text(
        _ chinese: String,
        language: AppLanguage,
        _ arguments: [CVarArg] = []
    ) -> String {
        let template = language.resolved() == .chinese ? chinese : english[chinese, default: chinese]
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: language.locale, arguments: arguments)
    }

    private static let english: [String: String] = [
        "准备就绪": "Ready",
        "准备添加新账号": "Ready to add an account",
        "设置": "Settings",
        "版本": "Version",
        "完成": "Done",
        "语言": "Language",
        "跟随系统": "Follow System",
        "中文": "中文",
        "英文": "English",
        "自动查询": "Automatic Refresh",
        "启用自动刷新": "Enable automatic refresh",
        "查询间隔": "Refresh interval",
        "刷新间隔": "Refresh interval",
        "间隔": "Interval",
        "单位": "Unit",
        "时间单位": "Time unit",
        "秒": "Seconds",
        "分钟": "Minutes",
        "自动查询默认每 1 分钟执行；可自定义秒或分钟。全量查询时账号之间间隔 1 秒，单账号查询立即执行。": "Automatic refresh runs every minute by default. You can choose seconds or minutes. Full refreshes wait one second between accounts; single-account refreshes run immediately.",
        "打开设置": "Open Settings",
        "增加账号": "Add Account",
        "刷新": "Refresh",
        "正在刷新": "Refreshing",
        "已载入 %d 个账号": "%d accounts loaded",
        "当前使用": "Current",
        "未识别": "Unknown",
        "切换": "Switch",
        "使用": "In Use",
        "下一个账号": "Next Account",
        "暂无可用账号": "No available account",
        "请刷新额度后重试": "Refresh usage and try again",
        "5 小时 %d%% · 周额度 %d%%": "5-hour %d%% · Weekly %d%%",
        "暂无额度信息": "No usage data",
        "所有账号": "All Accounts",
        "%d 个": "%d",
        "额度更新于 %@": "Usage updated %@",
        "5 小时": "5-hour",
        "周额度": "Weekly",
        "重置卡 %d 张": "Reset cards: %d",
        "重置 %@": "Resets %@",
        "立即查询此账号，不等待": "Refresh this account now",
        "账号操作": "Account actions",
        "设置别名": "Set Alias",
        "移除账号": "Remove Account",
        "切换账号": "Switch Account",
        "切换到 %@": "Switch to %@",
        "取消": "Cancel",
        "请先保存 ChatGPT 中的内容。确认后会关闭 ChatGPT，切换账号，再自动重新打开 ChatGPT。": "Save your work in ChatGPT first. ChatGPT will close, switch accounts, and reopen automatically.",
        "未检测到 ChatGPT。账号仍会正常切换，但不会自动打开 ChatGPT。": "ChatGPT was not found. The account will still switch, but ChatGPT will not open automatically.",
        "请先保存工作并退出 Codex CLI。确认后会关闭 ChatGPT、切换账号并重新打开 ChatGPT；完成后请重新打开 Codex CLI。": "Save your work and exit Codex CLI. ChatGPT will close, the account will switch, and ChatGPT will reopen. Reopen Codex CLI when finished.",
        "请先保存工作并退出 Codex CLI。确认后会切换账号；完成后请重新打开 Codex CLI。": "Save your work and exit Codex CLI. The account will switch; reopen Codex CLI when finished.",
        "移到废纸篓": "Move to Trash",
        "账号凭据将移到废纸篓，可以恢复；不会永久删除。": "The account credentials will be moved to Trash and can be restored. They will not be permanently deleted.",
        "等待新账号登录": "Waiting for new account login",
        "增加 Codex 账号": "Add Codex Account",
        "取消后会关闭 ChatGPT 应用。": "Cancelling will close ChatGPT.",
        "取消后会关闭 ChatGPT 应用并恢复原账号。": "Cancelling will close ChatGPT and restore the previous account.",
        "取消后会恢复原账号。": "Cancelling will restore the previous account.",
        "完成或取消后，请重新打开 Codex CLI。": "Reopen Codex CLI after completing or cancelling.",
        "先保存并退出所有正在运行的 Codex CLI": "Save your work and exit all running Codex CLI sessions",
        "继续后会关闭 ChatGPT 并保存当前账号": "Continuing will close ChatGPT and save the current account",
        "继续后会保存当前账号，并等待你运行 codex login": "Continuing will save the current account and wait for you to run codex login",
        "重新登录后会自动识别用户名和邮箱": "The username and email will be detected after you sign in",
        "正在恢复…": "Restoring…",
        "退出 ChatGPT 并继续": "Quit ChatGPT and Continue",
        "保存当前账号并继续": "Save Current Account and Continue",
        "设置账号别名": "Set Account Alias",
        "界面只显示别名；鼠标停留在别名上仍可查看原用户名和邮箱。": "The interface shows the alias. Hover over it to see the original username and email.",
        "别名": "Alias",
        "保存": "Save",
        "账号文件名：%@": "Account filename: %@",
        "原用户名：%@\n邮箱：%@": "Original username: %@\nEmail: %@",
        "请等待当前操作完成。": "Wait for the current operation to finish.",
        "添加账号前必须先切换到一个普通账号。": "Switch to a regular account before adding another account.",
        "新增账号需要先安装 ChatGPT。未修改任何账号文件。": "Install ChatGPT before adding an account. No account files were changed.",
        "正在检测 Codex CLI，请稍候。": "Detecting Codex CLI. Please wait.",
        "新增账号需要先安装 ChatGPT 或 Codex CLI。未修改任何账号文件。": "Install ChatGPT or Codex CLI before adding an account. No account files were changed.",
        "请先保存工作并退出所有正在运行的 Codex CLI。继续后会关闭 ChatGPT，并使用 ChatGPT 登录新账号。": "Save your work and exit all running Codex CLI sessions. Continuing will close ChatGPT and use it to sign in to a new account.",
        "继续后会关闭 ChatGPT，并使用 ChatGPT 登录新账号。": "Continuing will close ChatGPT and use it to sign in to a new account.",
        "请先保存工作并退出所有正在运行的 Codex CLI。继续后，请在终端运行 codex login。": "Save your work and exit all running Codex CLI sessions. Then continue and run codex login in Terminal.",
        "正在准备 Codex CLI 登录…": "Preparing Codex CLI sign-in…",
        "请打开终端运行 codex login，并在浏览器中完成登录。完成后请返回此处等待识别。": "Open Terminal, run codex login, and complete sign-in in your browser. Then return here and wait for detection.",
        "请先保存工作并退出所有正在运行的 Codex CLI。继续后，请在 ChatGPT 中登录新账号。": "Save your work and exit all running Codex CLI sessions. Then continue and sign in to the new account in ChatGPT.",
        "正在关闭 ChatGPT…": "Closing ChatGPT…",
        "请在 ChatGPT 中登录新账号。登录数据只保存在本机；本应用不会上传或展示登录凭据。": "Sign in to the new account in ChatGPT. Login data stays on this Mac; the app never uploads or displays credentials.",
        "已取消添加账号": "Account addition cancelled",
        "正在关闭登录窗口并恢复原账号…": "Closing the login window and restoring the original account…",
        "正在恢复原账号…": "Restoring the previous account…",
        "当前正在使用的账号不能移除，请先切换到其他账号。": "The account currently in use cannot be removed. Switch to another account first.",
        "账号已切换": "Account switched",
        "正在查询账号限额…": "Checking account usage…",
        "刷新完成": "Refresh complete",
        "刷新未完全成功": "Refresh did not fully complete",
        "账号查询失败": "Account refresh failed",
        "已刷新 %@": "Refreshed %@",
        "已恢复当前账号识别": "Current account identification restored",
        "已恢复上次未完成的新增账号": "Restored the account from the interrupted add-account flow",
        "已完成上次中断的新增账号": "Completed the interrupted add-account flow",
        "发现未完成的新增账号，但无法识别当前账号；现有凭据未修改。": "An interrupted add-account flow was found, but the current account could not be identified. Existing credentials were not changed.",
        "无法恢复上次未完成的新增账号：%@": "Could not restore the interrupted add-account flow: %@",
        "无法读取账号数据：%@": "Could not read account data: %@",
        "ChatGPT 未能关闭，请手动关闭后重试。账号文件未修改。": "ChatGPT could not be closed. Quit it manually and try again. Account files were not changed.",
        "添加失败，原账号已保留：%@": "Account addition failed; the original account was kept: %@",
        "恢复未完成：%@": "Restore did not complete: %@",
        "已将 %@ 的凭据移到废纸篓": "Moved %@ credentials to Trash",
        "移除失败：%@": "Removal failed: %@",
        "正在切换到 %@…": "Switching to %@…",
        "已切换到 %@，已打开 ChatGPT": "Switched to %@ and opened ChatGPT",
        "已切换到 %@，未检测到 ChatGPT，已跳过自动打开": "Switched to %@. ChatGPT was not found, so opening it was skipped.",
        "已切换到 %@，已打开 ChatGPT；请重新打开 Codex CLI": "Switched to %@ and opened ChatGPT. Reopen Codex CLI.",
        "已切换到 %@，请重新打开 Codex CLI": "Switched to %@. Reopen Codex CLI.",
        "账号已切换，请重新打开 Codex CLI": "Account switched. Reopen Codex CLI.",
        "已取消添加账号，请重新打开 Codex CLI": "Account addition cancelled. Reopen Codex CLI.",
        "添加失败，原账号已保留：%@ 请重新打开 Codex CLI。": "Account addition failed; the previous account was kept: %@ Reopen Codex CLI.",
        "已添加 %@，请重新打开 Codex CLI": "Added %@. Reopen Codex CLI.",
        "已切换账号，但无法打开 ChatGPT：%@": "The account was switched, but ChatGPT could not be opened: %@",
        "无法运行切换脚本：%@": "Could not run the switching script: %@",
        "已添加 %@": "Added %@",
        "切换失败": "Switch failed",
        "切换未开始": "Switch did not start",
        "账号": "Account",
        "中转站": "Hub",
        "推荐": "Recommended",
        "暂无账号数据": "No account data",
        "点击“立即刷新”读取账号限额。": "Select Refresh to load account usage.",
        "最近更新：%@": "Last updated: %@",
        "切换到推荐账号": "Switch to Recommended Account",
        "5 小时额度": "5-hour Usage",
        "重置卡": "Reset Cards",
        "需要时可使用": "Available when needed",
        "当前没有可用重置卡": "No reset cards available",
        "重置：%@": "Resets: %@",
        "当前账号": "Current account"
    ]
}
