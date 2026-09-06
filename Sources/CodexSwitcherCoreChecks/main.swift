import CodexSwitcherCore
import Foundation

guard ClientAvailability(hasChatGPT: true, hasCodexCLI: true).accountLoginMethod == .chatGPT,
      ClientAvailability(hasChatGPT: true, hasCodexCLI: false).accountLoginMethod == .chatGPT,
      ClientAvailability(hasChatGPT: false, hasCodexCLI: true).accountLoginMethod == .codexCLI,
      !ClientAvailability(hasChatGPT: false, hasCodexCLI: false).canAddAccount else {
    fatalError("客户端安装状态判断失败")
}

let data = """
{
  "current": {"five_hour_remaining": 90, "five_hour_reset": "2030-01-01 09:00", "weekly_remaining": 90, "weekly_reset": "1.2", "reset_cards": 0, "noted_at": "2026-09-05T10:00:00+08:00"},
  "nearest": {"five_hour_remaining": 40, "five_hour_reset": "2030-01-01 10:00", "weekly_remaining": 60, "weekly_reset": "1.2", "reset_cards": 1, "noted_at": "2026-09-05T10:00:00+08:00"},
  "later": {"five_hour_remaining": 50, "five_hour_reset": "2030-01-01 11:00", "weekly_remaining": 70, "weekly_reset": "1.2", "noted_at": "2026-09-05T10:00:00+08:00"},
  "invalid": {"five_hour_remaining": 100, "five_hour_reset": "2030-01-01 08:30", "weekly_remaining": 100, "weekly_reset": "1.2", "auth_invalid": true, "noted_at": "2026-09-05T10:00:00+08:00"},
  "weeklyZero": {"five_hour_remaining": 80, "five_hour_reset": "2030-01-01 09:30", "weekly_remaining": 0, "weekly_reset": "1.2", "noted_at": "2026-09-05T10:00:00+08:00"}
}
""".data(using: .utf8)!

let accounts = try UsageStore.decode(data)
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
guard let now = AccountRecommender.resetDate("2030-01-01 08:00", calendar: calendar) else {
    fatalError("无法构造测试时间")
}
let result = AccountRecommender.next(
    from: accounts,
    currentAccount: "current",
    now: now,
    calendar: calendar
)
precondition(result?.name == "nearest", "没有选中最近的合格账号")
precondition(result?.resetCards == 1, "没有解析重置卡")
let rankedNames = AccountRecommender.ranked(
    from: accounts,
    currentAccount: "current",
    now: now,
    calendar: calendar
).map(\.name)
precondition(rankedNames == ["nearest", "later", "current", "invalid", "weeklyZero"], "完整推荐顺序不正确")
precondition(accounts.first { $0.name == "invalid" }?.authInvalid == true, "没有解析登录失效状态")
print("账号数据解析与推荐算法检查通过。")

// 使用临时凭据验证恢复，不访问用户的真实账号目录。
func checkLoginCancellation() throws {
    func check(_ condition: Bool, _ message: String = "账号恢复结果不符合预期") { precondition(condition, message) }
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("login-check-\(UUID().uuidString)")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    let old = Data("old-credential".utf8)
    let new = Data("new-credential".utf8)
    let marker = Data("account old\n".utf8)
    func fixture(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        try old.write(to: dir.appendingPathComponent("auth.json"))
        try marker.write(to: dir.appendingPathComponent(".active-auth-profile"))
        return dir
    }
    func read(_ dir: URL, _ name: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent(name))
    }
    let plain = try fixture("cancel-before-login")
    let first = try AccountLoginSession(directory: plain, account: "old")
    try first.cancel()
    check(try read(plain, "auth.json") == old)
    check(try read(plain, ".active-auth-profile") == marker)
    precondition(!files.fileExists(atPath: plain.appendingPathComponent("auth.json.old").path))
    try first.cancel()
    check(try read(plain, "auth.json") == old, "重复取消不得移动旧账号")

    let late = try fixture("cancel-after-login-write")
    let second = try AccountLoginSession(directory: late, account: "old")
    try new.write(to: late.appendingPathComponent("auth.json"))
    try second.cancel()
    check(try read(late, "auth.json") == old)
    check(!files.fileExists(atPath: late.appendingPathComponent("cancelled-logins").path), "取消不应保留新凭据")
    check(try read(late, ".active-auth-profile") == marker)

    let success = try fixture("completed-login")
    let third = try AccountLoginSession(directory: success, account: "old")
    try new.write(to: success.appendingPathComponent("auth.json"))
    try third.complete(account: "new")
    try third.cancel()
    check(try read(success, "auth.json") == new, "完成后的取消不得撤销新账号")
    check(try read(success, "auth.json.old") == old)
    check(try read(success, ".active-auth-profile") == Data("account new\n".utf8))

    let conflict = try fixture("existing-backup")
    try new.write(to: conflict.appendingPathComponent("auth.json.old"))
    do {
        _ = try AccountLoginSession(directory: conflict, account: "old")
        fatalError("已有备份时应拒绝覆盖")
    } catch { }
    check(try read(conflict, "auth.json") == old)
    check(try read(conflict, "auth.json.old") == new)

    let missing = try fixture("missing-backup")
    let fourth = try AccountLoginSession(directory: missing, account: "old")
    try files.moveItem(at: missing.appendingPathComponent("auth.json.old"),
                       to: missing.appendingPathComponent("saved-old"))
    try new.write(to: missing.appendingPathComponent("auth.json"))
    do {
        try fourth.cancel()
        fatalError("备份丢失时应停止恢复")
    } catch { }
    check(try read(missing, "auth.json") == new)
    precondition(fourth.isPending)
    try files.moveItem(at: missing.appendingPathComponent("saved-old"),
                       to: missing.appendingPathComponent("auth.json.old"))
    try fourth.cancel()
    check(try read(missing, "auth.json") == old, "恢复失败后应能重试")
    print("添加账号取消检查通过：未登录、丢弃晚到凭据、重复取消、成功登记、备份冲突、恢复重试。")
}
try checkLoginCancellation()

func checkInterruptedAdditionRecovery() throws {
    func check(_ condition: Bool, _ message: String = "中断恢复结果不符合预期") { precondition(condition, message) }
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("interrupted-addition-\(UUID().uuidString)")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    let old = Data("old-credential".utf8)
    let new = Data("new-credential".utf8)
    let marker = Data("account old\n".utf8)
    func fixture(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try old.write(to: directory.appendingPathComponent("auth.json"))
        try marker.write(to: directory.appendingPathComponent(".active-auth-profile"))
        return directory
    }
    func read(_ directory: URL, _ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    let pendingName = ".codex-switcher-addition-pending.json"

    let beforeArchiveMove = try fixture("before-archive-move")
    try Data("{\"account\":\"old\",\"originalMarker\":\"account old\\n\"}".utf8)
        .write(to: beforeArchiveMove.appendingPathComponent(pendingName))
    guard case .none = try AccountLoginSession.recoverInterrupted(in: beforeArchiveMove) else {
        fatalError("尚未移动旧账号时应只清除进行中记录")
    }
    check(try read(beforeArchiveMove, "auth.json") == old)
    check(!files.fileExists(atPath: beforeArchiveMove.appendingPathComponent(pendingName).path))

    let beforeLogin = try fixture("before-login")
    _ = try AccountLoginSession(directory: beforeLogin, account: "old")
    guard case .restoredOriginal(let account) = try AccountLoginSession.recoverInterrupted(in: beforeLogin) else {
        fatalError("未登录中断应恢复旧账号")
    }
    check(account == "old")
    check(try read(beforeLogin, "auth.json") == old)
    check(try read(beforeLogin, ".active-auth-profile") == marker)
    check(!files.fileExists(atPath: beforeLogin.appendingPathComponent(pendingName).path))

    let afterLogin = try fixture("after-login")
    _ = try AccountLoginSession(directory: afterLogin, account: "old")
    try new.write(to: afterLogin.appendingPathComponent("auth.json"))
    guard case .needsRegistration(let original) = try AccountLoginSession.recoverInterrupted(in: afterLogin) else {
        fatalError("已有新凭据的中断应等待登记")
    }
    check(original == "old")
    try AccountLoginSession.finishPending(directory: afterLogin, account: "new")
    check(try read(afterLogin, "auth.json") == new)
    check(try read(afterLogin, "auth.json.old") == old)
    check(try read(afterLogin, ".active-auth-profile") == Data("account new\n".utf8))
    check(!files.fileExists(atPath: afterLogin.appendingPathComponent(pendingName).path))

    let damaged = try fixture("missing-backup")
    _ = try AccountLoginSession(directory: damaged, account: "old")
    try files.moveItem(at: damaged.appendingPathComponent("auth.json.old"), to: damaged.appendingPathComponent("saved-old"))
    do {
        _ = try AccountLoginSession.recoverInterrupted(in: damaged)
        fatalError("旧账号备份缺失时应停止恢复")
    } catch { }
    check(files.fileExists(atPath: damaged.appendingPathComponent(pendingName).path))
    print("新增账号中断恢复检查通过：未移动、未登录恢复、新登录登记、备份缺失保留现场。")
}
try checkInterruptedAdditionRecovery()

func checkTokenUsageTracking() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("token-usage-check-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    try files.createDirectory(at: sessions, withIntermediateDirectories: true)
    let log = sessions.appendingPathComponent("rollout.jsonl")
    func record(_ input: Int) -> String {
        """
        {"timestamp":"2026-09-06T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"2026-09-06T09:00:01.123Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":\(input + 20)}}}}
        """ + "\n"
    }
    func tokenRecord(_ input: Int) -> String {
        """
        {"timestamp":"2026-09-06T09:00:01.123Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":\(input + 20)}}}}
        """ + "\n"
    }
    try record(100).write(to: log, atomically: true, encoding: .utf8)
    let tracker = TokenUsageTracker(roots: [sessions], stateURL: root.appendingPathComponent("state.json"))
    let initial = try tracker.scan(account: "alpha")
    precondition(initial.isEmpty, "首次启用不应导入历史记录")
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(tokenRecord(240).utf8))
    try handle.close()
    let events = try tracker.scan(account: "alpha")
    precondition(events.count == 1 && events[0].input == 240, "没有只读取新增 Token 记录")
    precondition(events[0].model == "gpt-5.6-sol", "没有从启用位置之前恢复模型名称")
    let repeated = try tracker.scan(account: "alpha")
    precondition(repeated.count == 1, "重复扫描不应重复计数")
    let priceEvent = TokenUsageEvent(
        id: "price", account: "alpha", timestamp: Date(), model: "gpt-5.6-sol",
        input: 1_000_000, cachedInput: 500_000, cacheWriteInput: 0,
        output: 100_000, reasoningOutput: 20_000
    )
    precondition(abs((ModelPricing.estimatedUSD(for: priceEvent) ?? 0) - 4.2) < 0.0001, "缓存价格计算错误")
    print("Token 增量统计检查通过：忽略历史、读取新增、避免重复、分别计算缓存价格。")
}
try checkTokenUsageTracking()

func checkSwitchHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-history-check-\(UUID().uuidString)")
    let store = SwitchHistoryStore(url: root.appendingPathComponent("history.json"))
    precondition(store.load().isEmpty)
    _ = try store.append(SwitchHistoryRecord(fromAccount: "alpha", toAccount: "beta", result: .success))
    _ = try store.append(SwitchHistoryRecord(fromAccount: "beta", toAccount: "gamma", result: .failure, message: "test"))
    let records = store.load()
    precondition(records.count == 2 && records[0].toAccount == "gamma" && records[1].toAccount == "beta")
    print("切换记录检查通过：成功与失败记录按最新时间排列。")
}
try checkSwitchHistory()
