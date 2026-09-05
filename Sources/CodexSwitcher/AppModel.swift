import AppKit
import CodexSwitcherCore
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    struct AccountIdentity: Equatable {
        let originalName: String
        let email: String
    }

    @Published var accounts: [AccountUsage] = []
    @Published var currentType = ""
    @Published var currentName = ""
    @Published var selectedAccount: String?
    @Published var isRefreshing = false
    @Published var isSwitching = false
    @Published var status = "准备就绪"
    @Published var lastError: String?
    @Published var showingSwitchConfirmation = false
    @Published var pendingSwitchAccount: String?
    @Published var identities: [String: AccountIdentity] = [:]
    @Published var aliases: [String: String] = [:]
    @Published var refreshingAccounts: Set<String> = []
    @Published var showingAddAccount = false
    @Published var addAccountStage = "准备添加新账号"
    @Published var isWaitingForLogin = false
    @Published var isAddingAccount = false
    @Published var isCancellingLogin = false
    @Published var notice: String?
    @Published var editingAccount: String?
    @Published var editingAlias = ""
    @Published var removingAccount: String?
    @AppStorage("refreshIntervalValue") var refreshIntervalValue = 1
    @AppStorage("refreshIntervalUnit") var refreshIntervalUnit = "minutes"
    @AppStorage("automaticRefresh") var automaticRefresh = false
    @AppStorage("didMigrateEmailDefaultNames") private var didMigrateEmailDefaultNames = false

    private let codexDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    private let chatGPTURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    private var automaticTask: Task<Void, Never>?
    private var loginWatchTask: Task<Void, Never>?
    private var loginSession: AccountLoginSession?
    private var noticeTask: Task<Void, Never>?
    private var resetRefreshTasks: [String: Task<Void, Never>] = [:]
    private var triggeredResetKeys: Set<String> = []

    private enum StartupRecovery {
        case none
        case notice(String)
        case error(String)
    }

    var recommendation: AccountUsage? {
        AccountRecommender.next(
            from: accounts,
            currentAccount: currentType == "account" ? currentName : nil
        )
    }

    var rankedAccounts: [AccountUsage] {
        AccountRecommender.ranked(
            from: accounts,
            currentAccount: currentType == "account" ? currentName : nil
        )
    }

    var selected: AccountUsage? {
        accounts.first { $0.name == selectedAccount } ?? recommendation ?? accounts.first
    }

    func start() {
        let recovery = recoverInterruptedAddition()
        loadFromDisk()
        configureAutomaticRefresh()
        switch recovery {
        case .none:
            break
        case .notice(let message):
            showNotice(message)
        case .error(let message):
            lastError = message
        }
    }

    private func recoverInterruptedAddition() -> StartupRecovery {
        do {
            switch try AccountLoginSession.recoverInterrupted(in: codexDirectory) {
            case .none:
                return .none
            case .restoredOriginal:
                return .notice("已恢复上次未完成的新增账号")
            case .needsRegistration(let originalAccount):
                let active = codexDirectory.appendingPathComponent("auth.json")
                guard let activeIdentity = identity(from: active) else {
                    return .error("发现未完成的新增账号，但无法识别当前账号；现有凭据未修改。")
                }
                let archived = codexDirectory.appendingPathComponent("auth.json.\(originalAccount)")
                let registeredName: String
                if identity(from: archived) == activeIdentity {
                    registeredName = originalAccount
                } else {
                    registeredName = availableInternalName(for: activeIdentity)
                }
                try AccountLoginSession.finishPending(directory: codexDirectory, account: registeredName)
                return .notice("已完成上次中断的新增账号")
            }
        } catch {
            return .error("无法恢复上次未完成的新增账号：\(error.localizedDescription)")
        }
    }

    func loadFromDisk() {
        guard !isAddingAccount else { return }
        do {
            let marker = codexDirectory.appendingPathComponent(".active-auth-profile")
            let parts = (try? String(contentsOf: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", maxSplits: 1)
            if let parts, parts.count == 2 {
                currentType = String(parts[0])
                currentName = String(parts[1])
            } else if let recovered = recoverMissingActiveProfile() {
                currentType = "account"
                currentName = recovered
                try Data("account \(recovered)\n".utf8).write(to: marker, options: .atomic)
                status = "已恢复当前账号识别"
            } else {
                currentType = ""
                currentName = ""
            }

            let usageURL = codexDirectory.appendingPathComponent("account_usage.json")
            let knownNames = knownAccountNames()
            accounts = try UsageStore.decode(Data(contentsOf: usageURL)).filter { knownNames.contains($0.name) }
            aliases = loadAliases()
            identities = loadIdentities(for: knownNames)
            migrateLegacyAutomaticAliasesIfNeeded()
            if selectedAccount == nil { selectedAccount = recommendation?.name ?? accounts.first?.name }
            configureResetRefreshes()
            if status != "已恢复当前账号识别" {
                status = "已载入 \(accounts.count) 个账号"
            }
            lastError = nil
        } catch {
            lastError = "无法读取账号数据：\(error.localizedDescription)"
        }
    }

    func refresh() {
        guard !isAddingAccount, !isSwitching else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        status = "正在查询账号限额…"
        lastError = nil
        Task {
            let result = await runScript(["refresh"])
            isRefreshing = false
            loadFromDisk()
            if result.code == 0 {
                status = result.output.isEmpty ? "刷新完成" : result.output
            } else {
                lastError = result.output
                status = "刷新未完全成功"
            }
            configureAutomaticRefresh()
        }
    }

    func refresh(account: String) {
        guard !isAddingAccount, !isSwitching else { return }
        guard !refreshingAccounts.contains(account) else { return }
        refreshingAccounts.insert(account)
        lastError = nil
        Task {
            let result = await runScript(["refresh", account])
            refreshingAccounts.remove(account)
            loadFromDisk()
            if result.code == 0 {
                status = "已刷新 \(displayName(for: account))"
            } else {
                lastError = result.output
                status = "账号查询失败"
            }
        }
    }

    func displayName(for account: String) -> String {
        let alias = aliases[account]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = identities[account]
        let original = identity?.originalName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let alias, !alias.isEmpty { return alias }
        let emailName = identity?.email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        if !emailName.isEmpty { return emailName }
        return original.isEmpty ? account : original
    }

    func identityHelp(for account: String) -> String {
        guard let identity = identities[account] else { return "账号文件名：\(account)" }
        return "原用户名：\(identity.originalName)\n邮箱：\(identity.email)"
    }

    func beginEditingAlias(_ account: String) {
        editingAccount = account
        editingAlias = aliases[account] ?? displayName(for: account)
    }

    func saveAlias() {
        guard let account = editingAccount else { return }
        let value = editingAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { aliases.removeValue(forKey: account) } else { aliases[account] = value }
        saveAliases()
        editingAccount = nil
    }

    func prepareAddAccount() {
        guard !isAddingAccount, !isSwitching, !isRefreshing, refreshingAccounts.isEmpty, pendingSwitchAccount == nil else {
            showNotice("请等待当前操作完成。")
            return
        }
        guard currentType == "account", !currentName.isEmpty else {
            lastError = "添加账号前必须先切换到一个普通账号。"
            return
        }
        lastError = nil
        addAccountStage = "请先保存工作并退出所有正在运行的 Codex CLI。继续后，请在 ChatGPT 中登录新账号。"
        showingAddAccount = true
    }

    func startAddAccount() {
        guard !isAddingAccount, !isRefreshing, refreshingAccounts.isEmpty,
              pendingSwitchAccount == nil, currentType == "account", !currentName.isEmpty else { return }
        let archivedName = currentName
        isAddingAccount = true
        lastError = nil
        automaticTask?.cancel()
        resetRefreshTasks.values.forEach { $0.cancel() }
        addAccountStage = "正在关闭 ChatGPT…"
        loginWatchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await closeChatGPT()
                try Task.checkCancellation()
                loginSession = try AccountLoginSession(directory: codexDirectory, account: archivedName)
                addAccountStage = "请在 ChatGPT 中登录新账号。登录数据只保存在本机；本应用不会上传或展示登录凭据。"
                isWaitingForLogin = true
                try await NSWorkspace.shared.openApplication(at: chatGPTURL, configuration: NSWorkspace.OpenConfiguration())
                try Task.checkCancellation()
                try await watchForNewLogin()
            } catch {
                // 取消由 cancelLoginWatch 统一恢复；旧任务不得重新打开检测或显示错误。
                guard !Task.isCancelled else { return }
                await restoreLoginSession(failure: error.localizedDescription)
            }
        }
    }

    func cancelLoginWatch() {
        guard !isCancellingLogin else { return }
        guard isAddingAccount else {
            showingAddAccount = false
            showNotice("已取消添加账号")
            return
        }
        isCancellingLogin = true
        addAccountStage = "正在关闭登录窗口并恢复原账号…"
        let previousTask = loginWatchTask
        previousTask?.cancel()
        Task {
            // 等待正在打开应用的操作结束，再关闭它，防止恢复后又弹出登录窗口。
            await previousTask?.value
            await restoreLoginSession(failure: nil)
            isCancellingLogin = false
        }
    }

    private func closeChatGPT() async throws {
        let bundleID = Bundle(url: chatGPTURL)?.bundleIdentifier ?? "com.openai.codex"
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for application in applications { application.terminate() }
        for _ in 0..<50 {
            try Task.checkCancellation()
            if applications.allSatisfy({ $0.isTerminated }) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NSError(domain: "CodexSwitcher", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "ChatGPT 未能关闭，请手动关闭后重试。账号文件未修改。"
        ])
    }

    private func restoreLoginSession(failure: String?) async {
        do {
            if let session = loginSession {
                try await closeChatGPT()
                try session.cancel()
            }
            loginSession = nil
            isAddingAccount = false
            isWaitingForLogin = false
            showingAddAccount = false
            loadFromDisk()
            configureAutomaticRefresh()
            if let failure {
                lastError = "添加失败，原账号已保留：\(failure)"
            } else {
                lastError = nil
                showNotice("已取消添加账号")
            }
        } catch {
            // 保留恢复对象和备份，允许用户退出登录应用后再次取消。
            addAccountStage = "恢复未完成：\(error.localizedDescription)"
            lastError = addAccountStage
        }
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func requestRemove(_ account: String) {
        guard !isAddingAccount else { return }
        if currentType == "account" && currentName == account {
            lastError = "当前正在使用的账号不能移除，请先切换到其他账号。"
            return
        }
        removingAccount = account
    }

    func confirmRemove() {
        guard !isAddingAccount else { return }
        guard let account = removingAccount else { return }
        let credential = codexDirectory.appendingPathComponent("auth.json.\(account)")
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: credential, resultingItemURL: &trashedURL)
            aliases.removeValue(forKey: account)
            saveAliases()
            removingAccount = nil
            loadFromDisk()
            status = "已将 \(account) 的凭据移到废纸篓"
        } catch {
            lastError = "移除失败：\(error.localizedDescription)"
            removingAccount = nil
        }
    }

    func requestSwitch(to account: String) {
        guard !isAddingAccount, !isSwitching, !isRefreshing, refreshingAccounts.isEmpty else { return }
        pendingSwitchAccount = account
        showingSwitchConfirmation = true
    }

    func confirmSwitch() {
        guard !isAddingAccount, !isSwitching, !isRefreshing, refreshingAccounts.isEmpty else { return }
        guard let account = pendingSwitchAccount else { return }
        showingSwitchConfirmation = false
        isSwitching = true
        status = "正在关闭 ChatGPT…"
        Task {
            do {
                try await closeChatGPT()
                status = "正在切换到 \(account)…"
                let result = await runScript(["switch", account])
                loadFromDisk()
                guard result.code == 0 else {
                    lastError = result.output
                    status = "切换失败"
                    isSwitching = false
                    pendingSwitchAccount = nil
                    return
                }
                do {
                    try await NSWorkspace.shared.openApplication(at: chatGPTURL, configuration: NSWorkspace.OpenConfiguration())
                    status = "已切换到 \(account)，已打开 ChatGPT"
                    showNotice("账号已切换")
                } catch {
                    status = "账号已切换"
                    lastError = "已切换账号，但无法打开 ChatGPT：\(error.localizedDescription)"
                }
            } catch {
                lastError = error.localizedDescription
                status = "切换未开始"
            }
            isSwitching = false
            pendingSwitchAccount = nil
        }
    }

    func configureAutomaticRefresh() {
        automaticTask?.cancel()
        guard automaticRefresh, !isAddingAccount, !isSwitching else { return }
        let value = max(refreshIntervalValue, 1)
        let seconds = refreshIntervalUnit == "seconds" ? value : value * 60
        automaticTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func configureResetRefreshes(now: Date = Date()) {
        resetRefreshTasks.values.forEach { $0.cancel() }
        resetRefreshTasks.removeAll()

        let eligible = accounts.compactMap { account -> (AccountUsage, Date, String)? in
            guard
                account.weeklyRemaining > 0,
                let resetDate = AccountRecommender.resetDate(account.fiveHourReset)
            else { return nil }
            return (account, resetDate, "\(account.name)|\(account.fiveHourReset)")
        }
        let activeKeys = Set(eligible.map(\.2))
        triggeredResetKeys.formIntersection(activeKeys)

        for (account, resetDate, key) in eligible {
            if resetDate <= now {
                guard triggeredResetKeys.insert(key).inserted else { continue }
                refresh(account: account.name)
                continue
            }
            resetRefreshTasks[key] = Task { [weak self] in
                let seconds = resetDate.timeIntervalSinceNow
                if seconds > 0 {
                    try? await Task.sleep(for: .seconds(seconds))
                }
                guard !Task.isCancelled, let self else { return }
                guard self.triggeredResetKeys.insert(key).inserted else { return }
                self.resetRefreshTasks.removeValue(forKey: key)
                self.refresh(account: account.name)
            }
        }
    }

    private func runScript(_ arguments: [String]) async -> (code: Int32, output: String) {
        let script = codexDirectory.appendingPathComponent("switch-account.sh").path
        return await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: script)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (process.terminationStatus, text)
            } catch {
                return (1, "无法运行切换脚本：\(error.localizedDescription)")
            }
        }.value
    }

    private func watchForNewLogin() async throws {
        let authURL = codexDirectory.appendingPathComponent("auth.json")
        while true {
            try Task.checkCancellation()
            if let identity = identity(from: authURL), let session = loginSession {
                let internalName = availableInternalName(for: identity)
                // 此处到登记完成没有等待点，取消不会插入到一半。
                try session.complete(account: internalName)
                loginSession = nil
                isAddingAccount = false
                isWaitingForLogin = false
                showingAddAccount = false
                loadFromDisk()
                configureAutomaticRefresh()
                showNotice("已添加 \(displayName(for: internalName))")
                refresh(account: internalName)
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func knownAccountNames() -> Set<String> {
        var names = Set<String>()
        if currentType == "account", !currentName.isEmpty { names.insert(currentName) }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: codexDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("auth.json.") {
            let suffix = String(url.lastPathComponent.dropFirst("auth.json.".count))
            if suffix != "hub" && suffix != "bak" && !suffix.hasPrefix("hub.") {
                names.insert(suffix)
            }
        }
        return names
    }

    /// 标记意外丢失时，仅依据当前 auth.json 的公开身份字段恢复账号名；不读取或输出令牌。
    private func recoverMissingActiveProfile() -> String? {
        let active = codexDirectory.appendingPathComponent("auth.json")
        guard let activeIdentity = identity(from: active) else { return nil }

        let names = knownAccountNames()
        let identities = loadIdentities(for: names)
        if let matched = identities.first(where: { $0.value == activeIdentity })?.key {
            return matched
        }

        let emailPrefix = activeIdentity.email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        let normalized = emailPrefix.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "_"
        }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !normalized.isEmpty, !names.contains(normalized) else { return nil }
        return normalized
    }

    private func loadAliases() -> [String: String] {
        let url = codexDirectory.appendingPathComponent("account_aliases.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveAliases() {
        let url = codexDirectory.appendingPathComponent("account_aliases.json")
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func migrateLegacyAutomaticAliasesIfNeeded() {
        guard !didMigrateEmailDefaultNames else { return }
        aliases = aliases.filter { account, alias in
            let original = identities[account]?.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
            return alias.trimmingCharacters(in: .whitespacesAndNewlines) != original
        }
        saveAliases()
        didMigrateEmailDefaultNames = true
    }

    private func loadIdentities(for names: Set<String>) -> [String: AccountIdentity] {
        var result: [String: AccountIdentity] = [:]
        for name in names {
            let url = currentType == "account" && currentName == name
                ? codexDirectory.appendingPathComponent("auth.json")
                : codexDirectory.appendingPathComponent("auth.json.\(name)")
            if let value = identity(from: url) { result[name] = value }
        }
        return result
    }

    private func identity(from url: URL) -> AccountIdentity? {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let idToken = tokens["id_token"] as? String,
            let payload = decodeJWTPayload(idToken)
        else { return nil }
        let name = payload["name"] as? String ?? ""
        let email = payload["email"] as? String ?? ""
        guard !name.isEmpty || !email.isEmpty else { return nil }
        return AccountIdentity(originalName: name.isEmpty ? email : name, email: email)
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func availableInternalName(for identity: AccountIdentity) -> String {
        let source = identity.email.split(separator: "@", maxSplits: 1).first.map(String.init)
            ?? (identity.originalName.isEmpty ? "account" : identity.originalName)
        let allowed = source.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "_"
        }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = allowed.isEmpty ? "account" : allowed
        let existing = knownAccountNames()
        if !existing.contains(base) { return base }
        var number = 2
        while existing.contains("\(base)_\(number)") { number += 1 }
        return "\(base)_\(number)"
    }
}
