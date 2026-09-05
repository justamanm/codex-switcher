import Foundation

public enum InterruptedAddition {
    case none
    case restoredOriginal(account: String)
    case needsRegistration(originalAccount: String)
}

/// 调用方须先确认登录应用已经退出，再开始或撤销文件变更。
public final class AccountLoginSession {
    private struct PendingAddition: Codable {
        let account: String
        let originalMarker: String
    }

    private let directory: URL
    private let active: URL
    private let archived: URL
    private let marker: URL
    private let pending: URL
    private let originalMarker: Data
    private var restored = false
    public private(set) var isPending = true

    public init(directory: URL, account: String) throws {
        try Self.validate(account)
        self.directory = directory
        active = directory.appendingPathComponent("auth.json")
        archived = directory.appendingPathComponent("auth.json.\(account)")
        marker = directory.appendingPathComponent(".active-auth-profile")
        pending = Self.pendingURL(in: directory)
        originalMarker = try Data(contentsOf: marker)
        guard FileManager.default.fileExists(atPath: active.path) else { throw Self.failure("找不到当前 auth.json。") }
        guard !FileManager.default.fileExists(atPath: archived.path) else { throw Self.failure("旧账号备份已存在，为避免覆盖已停止。") }
        guard !FileManager.default.fileExists(atPath: pending.path) else { throw Self.failure("已有未完成的新增账号操作，请重新打开应用完成恢复。") }
        do {
            try Self.writePending(PendingAddition(account: account, originalMarker: String(decoding: originalMarker, as: UTF8.self)), to: pending)
            try FileManager.default.moveItem(at: active, to: archived)
        } catch {
            try? FileManager.default.removeItem(at: pending)
            if FileManager.default.fileExists(atPath: archived.path), !FileManager.default.fileExists(atPath: active.path) {
                try? FileManager.default.moveItem(at: archived, to: active)
            }
            throw error
        }
    }

    public func complete(account: String) throws {
        guard isPending, !restored else { throw Self.failure("添加流程已经结束。") }
        try Self.finishPending(directory: directory, account: account)
        isPending = false
    }

    public func cancel() throws {
        guard isPending else { return }
        let files = FileManager.default
        if !restored {
            guard files.fileExists(atPath: archived.path) else { throw Self.failure("找不到旧账号备份，已停止恢复，现有凭据未覆盖。") }
            if files.fileExists(atPath: active.path) {
                try files.removeItem(at: active)
            }
            try files.moveItem(at: archived, to: active)
            restored = true
        }
        try originalMarker.write(to: marker, options: .atomic)
        try files.removeItem(at: pending)
        isPending = false
    }

    /// 仅处理上一次 Switcher 意外退出留下的文件状态，不读取或输出凭据内容。
    public static func recoverInterrupted(in directory: URL) throws -> InterruptedAddition {
        let pendingURL = pendingURL(in: directory)
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { return .none }
        let record = try JSONDecoder().decode(PendingAddition.self, from: Data(contentsOf: pendingURL))
        try validate(record.account)
        let active = directory.appendingPathComponent("auth.json")
        let archived = directory.appendingPathComponent("auth.json.\(record.account)")
        let marker = directory.appendingPathComponent(".active-auth-profile")
        let files = FileManager.default
        if !files.fileExists(atPath: archived.path), files.fileExists(atPath: active.path) {
            try files.removeItem(at: pendingURL)
            return .none
        }
        guard files.fileExists(atPath: archived.path) else { throw failure("上次新增账号的旧账号备份不存在，未修改现有凭据。") }
        if files.fileExists(atPath: active.path) { return .needsRegistration(originalAccount: record.account) }
        try files.moveItem(at: archived, to: active)
        try Data(record.originalMarker.utf8).write(to: marker, options: .atomic)
        try files.removeItem(at: pendingURL)
        return .restoredOriginal(account: record.account)
    }

    /// 新凭据已存在时，完成上一次未完成的新增账号登记。
    public static func finishPending(directory: URL, account: String) throws {
        try validate(account)
        let active = directory.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: active.path) else { throw failure("找不到待登记的新账号凭据。") }
        try Data("account \(account)\n".utf8).write(to: directory.appendingPathComponent(".active-auth-profile"), options: .atomic)
        try FileManager.default.removeItem(at: pendingURL(in: directory))
    }

    private static func pendingURL(in directory: URL) -> URL { directory.appendingPathComponent(".codex-switcher-addition-pending.json") }

    private static func writePending(_ record: PendingAddition, to url: URL) throws {
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func validate(_ account: String) throws {
        guard !account.isEmpty, !account.contains("/"), account != ".", account != ".." else { throw failure("账号名称无效。") }
    }

    private static func failure(_ message: String) -> NSError { NSError(domain: "CodexSwitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
