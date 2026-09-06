import AppKit
import CodexSwitcherCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSettings = false
    @State private var accountsWidth: CGFloat = 0
    @State private var selectedSection = DashboardSection.accounts
    @AppStorage("tokenUsageSortPeriod") private var tokenUsageSortPeriod = TokenUsageSortPeriod.fiveHours.rawValue
    private let accent = Color(red: 0.31, green: 0.57, blue: 0.39)

    private enum DashboardSection: String, CaseIterable {
        case accounts
        case tokenUsage
        case switchHistory
    }

    private enum TokenUsageSortPeriod: String, CaseIterable {
        case fiveHours
        case weeklyQuotaCycle
        case today
        case currentWeek

        var usagePeriod: TokenUsagePeriod {
            switch self {
            case .fiveHours: .fiveHours
            case .weeklyQuotaCycle: .weeklyQuotaCycle
            case .today: .today
            case .currentWeek: .currentWeek
            }
        }

        var title: String {
            switch self {
            case .fiveHours: "5h"
            case .weeklyQuotaCycle: "周额度周期"
            case .today: "今天"
            case .currentWeek: "本周"
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            dashboardContent
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onAppear { accountsWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in accountsWidth = width }
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .task { model.start() }
    }

    private var dashboardContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader
                if selectedSection == .accounts {
                    accountOverview
                }
                if let error = model.lastError { errorCard(error) }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            Group {
                switch selectedSection {
                case .accounts:
                    ScrollView {
                        accountsSection
                            .padding(.horizontal, 44)
                            .padding(.top, 16)
                            .padding(.bottom, 36)
                    }
                case .tokenUsage:
                    tokenUsageSection
                case .switchHistory:
                    switchHistorySection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 6)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $model.showingSwitchConfirmation, onDismiss: { model.pendingSwitchAccount = nil }) {
            switchAccountSheet
        }
        .alert(
            model.text("移除账号"),
            isPresented: Binding(
                get: { model.removingAccount != nil },
                set: { if !$0 { model.removingAccount = nil } }
            )
        ) {
            Button(model.text("移到废纸篓"), role: .destructive) { model.confirmRemove() }
            Button(model.text("取消"), role: .cancel) { model.removingAccount = nil }
        } message: {
            Text(model.text("账号凭据将移到废纸篓，可以恢复；不会永久删除。"))
        }
        .sheet(isPresented: $model.showingAddAccount) {
            addAccountSheet.interactiveDismissDisabled(model.isAddingAccount)
        }
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .sheet(
            isPresented: Binding(
                get: { model.editingAccount != nil },
                set: { if !$0 { model.editingAccount = nil } }
            )
        ) { aliasSheet }
    }

    private var pageHeader: some View {
        HStack(spacing: 12) {
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .help(model.text("打开设置"))
            HStack(spacing: 7) {
                Circle().fill(model.lastError == nil ? .green : .orange).frame(width: 8, height: 8)
                Text(model.text("已载入 %d 个账号", model.accounts.count)).foregroundStyle(.secondary)
            }
            .font(.callout)
            Spacer()
            Picker("", selection: $selectedSection) {
                Label(model.text("账号"), systemImage: "person.2.fill")
                    .tag(DashboardSection.accounts)
                Label(model.text("Token 统计"), systemImage: "chart.bar.xaxis")
                    .tag(DashboardSection.tokenUsage)
                Label(model.text("切换记录"), systemImage: "clock.arrow.circlepath")
                    .tag(DashboardSection.switchHistory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
            .onChange(of: selectedSection) { _, section in
                if section == .tokenUsage { model.refreshTokenUsage() }
            }
            Button { model.prepareAddAccount() } label: {
                Label(model.text("增加账号"), systemImage: "person.badge.plus")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .controlSize(.large)
            .disabled(model.isSwitching)
            Button { model.refresh() } label: {
                Label(model.text(model.isRefreshing ? "正在刷新" : "刷新"), systemImage: "arrow.clockwise")
                    .frame(minWidth: 62)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isRefreshing || model.isSwitching)
        }
    }

    private var accountOverview: some View {
        HStack(spacing: 0) {
            overviewAccount(
                title: model.text("当前使用"),
                name: model.currentName.isEmpty ? model.text("未识别") : model.displayName(for: model.currentName),
                identityHelp: model.identityHelp(for: model.currentName),
                account: model.accounts.first { $0.name == model.currentName },
                systemImage: model.currentType == "hub" ? "network" : "person.crop.circle.fill"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 80)

            if let account = model.recommendation {
                VStack(spacing: 3) {
                    Button { model.requestSwitch(to: account.name) } label: {
                        Text(model.text("切换")).frame(width: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(model.isSwitching)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(accent)
                }
                .frame(width: 76)
                .layoutPriority(2)
            } else {
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 76)
            }

            if let account = model.recommendation {
                overviewAccount(
                    title: model.text("下一个账号"),
                    name: model.displayName(for: account.name),
                    identityHelp: model.identityHelp(for: account.name),
                    account: account,
                    systemImage: "leaf.fill"
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 32)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.text("下一个账号")).font(.callout.weight(.semibold)).foregroundStyle(accent)
                    Text(model.text("暂无可用账号")).font(.title3.bold())
                    Text(model.text("请刷新额度后重试")).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 32)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.22)))
    }

    private func overviewAccount(
        title: String,
        name: String,
        identityHelp: String,
        account: AccountUsage?,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                if accountsWidth > 0 && accountsWidth < 900 {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(accent)
                    HoverAccountName(name: name, identityHelp: identityHelp, font: .title3.bold())
                        .lineLimit(1)
                        .layoutPriority(1)
                    overviewUsage(account)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        HoverAccountName(name: name, identityHelp: identityHelp, font: .title3.bold())
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                    overviewUsage(account)
                }
            }
        }
        .frame(minWidth: 0)
    }

    private func overviewUsage(_ account: AccountUsage?) -> some View {
        Group {
            if let account {
                Text(model.text("5 小时 %d%% · 周额度 %d%%", account.fiveHourRemaining, account.weeklyRemaining))
            } else {
                Text(model.text("暂无额度信息"))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.text("所有账号")).font(.title3.bold())
                Text(model.text("%d 个", model.accounts.count)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let latestUpdate {
                    Label(model.text("额度更新于 %@", latestUpdate), systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            LazyVStack(spacing: 10) {
                ForEach(model.rankedAccounts) { account in
                    AccountDashboardRow(
                        account: account,
                        displayName: model.displayName(for: account.name),
                        identityHelp: model.identityHelp(for: account.name),
                        isCurrent: model.currentType == "account" && model.currentName == account.name,
                        isRecommended: model.recommendation?.name == account.name,
                        usesCompactLayout: accountsWidth > 0 && accountsWidth < 900,
                        isRefreshing: model.refreshingAccounts.contains(account.name),
                        isSwitching: model.isSwitching,
                        refreshAction: { model.refresh(account: account.name) },
                        switchAction: { model.requestSwitch(to: account.name) },
                        aliasAction: { model.beginEditingAlias(account.name) },
                        removeAction: { model.requestRemove(account.name) }
                    )
                }
            }
        }
    }

    private var latestUpdate: String? {
        let formatter = ISO8601DateFormatter()
        guard let date = model.accounts.compactMap({ formatter.date(from: $0.notedAt) }).max() else {
            return nil
        }
        return date.formatted(
            .dateTime
                .year().month(.abbreviated).day()
                .hour().minute()
                .locale(model.appLanguage.locale)
        )
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label(model.text("设置"), systemImage: "gearshape.fill").font(.title2.bold())
                Spacer()
                Button(model.text("完成")) { showingSettings = false }.keyboardShortcut(.defaultAction)
            }
            Divider()
            Label(model.text("语言"), systemImage: "globe").font(.headline)
            Picker(model.text("语言"), selection: $model.appLanguage) {
                Text(model.text("跟随系统")).tag(AppLanguage.system)
                Text("中文").tag(AppLanguage.chinese)
                Text("English").tag(AppLanguage.english)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            Label(model.text("自动查询"), systemImage: "clock.arrow.circlepath").font(.headline)
            HStack(spacing: 22) {
                Toggle(model.text("启用自动刷新"), isOn: $model.automaticRefresh)
                    .toggleStyle(.switch)
                    .onChange(of: model.automaticRefresh) { _, _ in model.configureAutomaticRefresh() }
                Spacer()
                Text(model.text("查询间隔")).foregroundStyle(.secondary)
                TextField(model.text("间隔"), value: $model.refreshIntervalValue, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    .onChange(of: model.refreshIntervalValue) { _, value in
                        if value < 1 { model.refreshIntervalValue = 1 }
                        model.configureAutomaticRefresh()
                    }
                Picker(model.text("时间单位"), selection: $model.refreshIntervalUnit) {
                    Text(model.text("秒")).tag("seconds")
                    Text(model.text("分钟")).tag("minutes")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .onChange(of: model.refreshIntervalUnit) { _, _ in model.configureAutomaticRefresh() }
            }
            Text(model.text("自动查询默认每 1 分钟执行；可自定义秒或分钟。全量查询时账号之间间隔 1 秒，单账号查询立即执行。"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text(model.text("版本"))
                Spacer()
                Text(AppVersion.display)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520)
    }

    private func errorCard(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var tokenUsageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(model.text("Token 统计")).font(.title3.bold())
                Spacer()
                HStack(spacing: 14) {
                    Text(model.text("仅统计启用此功能后的本机记录"))
                        .font(.caption).foregroundStyle(.secondary)
                    Picker(model.text("排序"), selection: $tokenUsageSortPeriod) {
                        ForEach(TokenUsageSortPeriod.allCases, id: \.rawValue) { option in
                            Text(model.text(option.title)).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 165)
                }
            }
            .padding(.horizontal, 44).padding(.vertical, 16)
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(tokenUsageSortedAccounts) { account in
                        tokenUsageAccountRow(account)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Text(model.text("总计包含缓存 Token。价格为 OpenAI API 等值估算，使用美元；* 表示仅部分用量可估算。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tokenUsageSortedAccounts: [AccountUsage] {
        let selected = TokenUsageSortPeriod(rawValue: tokenUsageSortPeriod) ?? .fiveHours
        return model.rankedAccounts.enumerated().sorted { lhs, rhs in
            let left = model.tokenTotals(for: lhs.element.name, period: selected.usagePeriod).total
            let right = model.tokenTotals(for: rhs.element.name, period: selected.usagePeriod).total
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    private func tokenUsageAccountRow(_ account: AccountUsage) -> some View {
        let isCurrent = model.currentType == "account" && model.currentName == account.name
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(model.displayName(for: account.name))
                        .font(.headline)
                        .lineLimit(1)
                    if isCurrent {
                        Text(model.text("当前使用"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                }
                .foregroundStyle(isCurrent ? accent : Color.primary)
                Text(account.creditBalance.map { model.text("Credit 余额：$%.2f", $0) } ?? model.text("Credit 余额：未启用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 155, alignment: .leading)

            Divider().padding(.vertical, 4)

            tokenUsagePeriod(
                title: "5h",
                totals: model.tokenTotals(for: account.name, period: .fiveHours)
            )
            Divider().padding(.vertical, 4)
            tokenUsagePeriod(
                title: "周额度周期",
                subtitle: model.weeklyQuotaPeriodText(for: account.name) ?? model.text("暂无精确重置时间"),
                totals: model.tokenTotals(for: account.name, period: .weeklyQuotaCycle),
                unavailable: model.weeklyQuotaPeriodText(for: account.name) == nil,
                projection: model.weeklyQuotaProjections[account.name]
            )
            Divider().padding(.vertical, 4)
            tokenUsagePeriod(
                title: "今天",
                totals: model.tokenTotals(for: account.name, period: .today)
            )
            Divider().padding(.vertical, 4)
            tokenUsagePeriod(
                title: "本周",
                totals: model.tokenTotals(for: account.name, period: .currentWeek)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isCurrent ? accent.opacity(0.07) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isCurrent ? accent.opacity(0.45) : Color.secondary.opacity(0.15),
                    lineWidth: 1
                )
        }
    }

    private func tokenUsagePeriod(
        title: String,
        subtitle: String? = nil,
        totals: TokenUsageTotals,
        unavailable: Bool = false,
        projection: WeeklyQuotaProjection? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.text(title)).font(.callout.weight(.semibold))
                Spacer()
                if !unavailable { Text(compactTokens(totals.total)).font(.headline) }
            }
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(2)
            }
            if !unavailable {
                Text(model.text("输入 %@ · 缓存 %@", compactTokens(totals.input), compactTokens(totals.cachedInput)))
                Text(model.text("输出 %@ · 推理 %@", compactTokens(totals.output), compactTokens(totals.reasoningOutput)))
                Text(tablePriceText(totals)).foregroundStyle(.secondary)
                if let projection {
                    Text(model.text(
                        projection.isPartial ? "周额度预测 $%.2f*（依据 %d%% 用量）" : "周额度预测 $%.2f（依据 %d%% 用量）",
                        projection.estimatedFullUSD,
                        projection.observedUsedPercent
                    ))
                    .foregroundStyle(.secondary)
                } else if title == "周额度周期" {
                    Text(model.text("周额度预测：暂无数据"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tablePriceText(_ totals: TokenUsageTotals) -> String {
        if totals.unpricedEvents == 0 { return String(format: "$%.4f", totals.estimatedUSD) }
        if totals.estimatedUSD > 0 { return String(format: "$%.4f*", totals.estimatedUSD) }
        return model.text("暂无法估算")
    }

    private var switchHistorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(model.text("切换记录")).font(.title3.bold())
                Spacer()
                Text(model.text("仅保存在本机，最多保留 500 条"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 44).padding(.vertical, 16)
            Divider()
            if model.switchHistory.isEmpty {
                ContentUnavailableView(
                    model.text("暂无切换记录"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(model.text("完成一次账号切换后会显示在这里。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(model.switchHistory) { record in
                    HStack(spacing: 14) {
                        Image(systemName: record.result == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(record.result == .success ? Color.green : Color.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.text("%@ → %@", model.displayName(for: record.fromAccount), model.displayName(for: record.toAccount)))
                                .font(.headline)
                            Text(record.timestamp.formatted(
                                .dateTime.year().month().day().hour().minute().second().locale(model.appLanguage.locale)
                            ))
                            .font(.caption).foregroundStyle(.secondary)
                            if !record.message.isEmpty {
                                Text(record.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(model.text(record.result == .success ? "成功" : "失败"))
                            .font(.callout.weight(.medium))
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }

    private var switchAccountSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.system(size: 24)).foregroundStyle(accent)
                Text(model.text("切换账号"))
                    .font(.title2.bold())
            }
            Text(model.text("切换前请确认以下事项。"))
                .foregroundStyle(.secondary)
            Label(model.text("将账号切换到 %@", model.pendingSwitchAccount ?? ""), systemImage: "person.crop.circle.badge.checkmark")
                .font(.callout)
            HStack(alignment: .top, spacing: 12) {
                if model.isChatGPTInstalled {
                    switchInstructionCard(
                        title: "ChatGPT（自动操作）",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        steps: [
                            ("确认后自动关闭", "power"),
                            ("切换完成后自动重新打开", "arrow.up.forward.app")
                        ]
                    )
                }
                if model.isCodexCLIInstalled {
                    switchInstructionCard(
                        title: "Codex CLI（需手动关闭和重启）",
                        systemImage: "terminal.fill",
                        steps: [
                            ("切换前保存工作并退出", "terminal"),
                            ("切换完成后手动重新打开", "arrow.clockwise")
                        ]
                    )
                }
            }
            HStack {
                Spacer()
                Button(model.text("取消")) {
                    model.showingSwitchConfirmation = false
                    model.pendingSwitchAccount = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(model.text("切换到 %@", model.pendingSwitchAccount ?? "")) { model.confirmSwitch() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 620)
    }

    private func switchInstructionCard(
        title: String,
        systemImage: String,
        steps: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.text(title), systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(accent)
            Divider()
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                Label(model.text(step.0), systemImage: step.1)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var addAccountSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: model.isWaitingForLogin ? "person.crop.circle.badge.clock" : "person.badge.plus")
                .font(.system(size: 40)).foregroundStyle(accent)
            Text(model.text(model.isWaitingForLogin ? "等待新账号登录" : "增加 Codex 账号"))
                .font(.title2.bold())
            if model.isWaitingForLogin {
                Text(model.addAccountStage).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ProgressView().controlSize(.large)
                Text(model.text(model.addAccountUsesChatGPT
                    ? "取消后会关闭 ChatGPT 应用并恢复原账号。"
                    : "取消后会恢复原账号。"))
                    .font(.caption).foregroundStyle(.secondary)
                if model.isCodexCLIInstalled {
                    Text(model.text("完成或取消后，请重新打开 Codex CLI。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if model.isCodexCLIInstalled {
                        Label(model.text("先保存并退出所有正在运行的 Codex CLI"), systemImage: "terminal")
                    }
                    if model.isChatGPTInstalled {
                        Label(model.text("继续后会关闭 ChatGPT，保留当前登录账号，只需在 ChatGPT 完成登录即可"), systemImage: "arrow.down.doc")
                    } else {
                        Label(model.text("继续后会保存当前账号，并等待你运行 codex login"), systemImage: "arrow.down.doc")
                    }
                }
                .font(.callout)
            }
            HStack {
                Spacer()
                Button(model.text(model.isCancellingLogin ? "正在恢复…" : "取消")) { model.cancelLoginWatch() }
                    .disabled(model.isCancellingLogin)
                    .keyboardShortcut(.cancelAction)
                if !model.isAddingAccount {
                    Button(model.text(model.isChatGPTInstalled ? "退出 ChatGPT 并继续" : "保存当前账号并继续")) { model.startAddAccount() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(26).frame(width: 470)
    }

    private var aliasSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text("设置账号别名")).font(.title2.bold())
            Text(model.text("界面只显示别名；鼠标停留在别名上仍可查看用户名和邮箱。"))
                .foregroundStyle(.secondary)
            TextField(model.text("别名"), text: $model.editingAlias)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(model.text("取消")) { model.editingAccount = nil }
                Button(model.text("保存")) { model.saveAlias() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 420)
    }
}

private struct AccountDashboardRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingActions = false
    private let accent = Color(red: 0.31, green: 0.57, blue: 0.39)
    let account: AccountUsage
    let displayName: String
    let identityHelp: String
    let isCurrent: Bool
    let isRecommended: Bool
    let usesCompactLayout: Bool
    let isRefreshing: Bool
    let isSwitching: Bool
    let refreshAction: () -> Void
    let switchAction: () -> Void
    let aliasAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        Group {
            if usesCompactLayout {
                compactLayout
            } else {
                wideLayout
            }
        }
        .padding(.horizontal, usesCompactLayout ? 24 : 15)
        .padding(.vertical, usesCompactLayout ? 5 : 9)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isRecommended ? accent.opacity(0.38) : Color.secondary.opacity(0.16))
        )
    }

    private var wideLayout: some View {
        GeometryReader { geometry in
            let quotaAreaWidth = max(350, geometry.size.width - 393)
            let extraWidth = max(0, quotaAreaWidth - 350)
            let fiveHourWidth = 175 + extraWidth * 0.6
            let weeklyWidth = 175 + extraWidth * 0.4
            let sharedBarWidth = max(40, weeklyWidth - 150)
            HStack(spacing: 12) {
                accountIdentity
                    .frame(width: 115, alignment: .leading)
                Divider().frame(height: 28)
                QuotaBar(
                    title: model.text("5 小时"),
                    value: account.fiveHourRemaining,
                    reset: account.fiveHourReset,
                    barWidth: sharedBarWidth
                )
                    .frame(width: fiveHourWidth)
                Divider().frame(height: 28)
                QuotaBar(
                    title: model.text("周额度"),
                    value: account.weeklyRemaining,
                    reset: account.weeklyReset,
                    barWidth: sharedBarWidth
                )
                    .frame(width: weeklyWidth)
                Divider().frame(height: 28)
                Text(model.text("重置卡 %d 张", account.resetCards))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 68, alignment: .leading)
                Divider().frame(height: 28)
                accountActions
                    .frame(width: 110, alignment: .trailing)
            }
        }
        .frame(height: 28)
    }

    private var compactLayout: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                accountIdentity
                Spacer(minLength: 8)
                accountActions
            }
            Divider().opacity(0.55)
            GeometryReader { geometry in
                let quotaAreaWidth = max(0, geometry.size.width - 130)
                let sharedBarWidth = max(40, min(80, quotaAreaWidth / 2 - 175))
                HStack(spacing: 12) {
                    QuotaBar(
                        title: model.text("5 小时"),
                        value: account.fiveHourRemaining,
                        reset: account.fiveHourReset,
                        barWidth: sharedBarWidth
                    )
                    .frame(width: quotaAreaWidth / 2 + 24)
                    Divider().frame(height: 24)
                    QuotaBar(
                        title: model.text("周额度"),
                        value: account.weeklyRemaining,
                        reset: account.weeklyReset,
                        barWidth: sharedBarWidth
                    )
                    .frame(width: quotaAreaWidth / 2 - 24)
                    Divider().frame(height: 24)
                    resetCards
                }
            }
            .frame(height: 24)
        }
    }

    private var accountIdentity: some View {
        HStack(spacing: 6) {
            HoverAccountName(name: displayName, identityHelp: identityHelp, font: .headline)
                .foregroundStyle(accountNameColor)
                .lineLimit(1)
            if account.authInvalid {
                Text(model.text("登录已失效"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.red.opacity(0.09), in: Capsule())
                    .help(model.text("不会自动查询；重新登录后可手动刷新恢复。"))
            }
        }
    }

    private var resetCards: some View {
            Text(model.text("重置卡 %d 张", account.resetCards))
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 80, alignment: .leading)
    }

    private var accountActions: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Button { refreshAction() } label: {
                    ZStack {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 15, weight: .light))
                        }
                    }
                    .frame(width: 23, height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .hoverHint(model.text(account.authInvalid ? "重新登录后手动查询此账号" : "立即查询此账号，不等待"))
                .disabled(isRefreshing || isSwitching)

                Button { showingActions.toggle() } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15, weight: .light))
                        .frame(width: 23, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .hoverHint(model.text("账号操作"))
                .disabled(isSwitching)
                .popover(isPresented: $showingActions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            showingActions = false
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(120))
                                aliasAction()
                            }
                        } label: {
                            Label(model.text("设置别名"), systemImage: "pencil")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .frame(maxWidth: .infinity)

                        Button(role: .destructive) {
                            showingActions = false
                            removeAction()
                        } label: {
                            Label(model.text("移除账号"), systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(isCurrent)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 130)
                    .padding(12)
                }
            }
            if isRecommended {
                Button { switchAction() } label: {
                    Text(model.text("切换")).frame(width: 44)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isSwitching)
            } else {
                Button { switchAction() } label: {
                    Text(model.text(isCurrent ? "使用" : "切换")).frame(width: 44)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isCurrent || isSwitching)
            }
        }
    }

    private var accountNameColor: Color {
        if isCurrent { return .primary }
        if isRecommended { return accent }
        return .primary
    }

}

private struct QuotaBar: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let value: Int
    let reset: String
    var barWidth: CGFloat? = nil

    private let accentDark = Color(red: 0.12, green: 0.30, blue: 0.18)
    private var color: Color { value == 0 ? .red : accentDark }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text("\(value)%")
                .font(.callout.bold())
                .foregroundStyle(color)
                .frame(width: 35, alignment: .trailing)
            ProgressView(value: Double(value), total: 100)
                .tint(color)
                .frame(width: barWidth)
                .frame(minWidth: barWidth == nil ? 40 : nil, maxWidth: barWidth == nil ? .infinity : nil)
            Text(model.text("重置 %@", compactReset))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: 88, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactReset: String {
        reset.count >= 16 ? String(reset.dropFirst(5)) : reset
    }
}

private struct HoverAccountName: View {
    let name: String
    let identityHelp: String
    let font: Font
    @State private var isPresented = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Text(name)
            .font(font)
            .onHover { hovering in
                if hovering {
                    showPopover()
                } else {
                    scheduleDismiss()
                }
            }
            .popover(
                isPresented: $isPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                Text(identityHelp)
                    .font(.callout)
                    .foregroundColor(Color(nsColor: .labelColor))
                    .lineLimit(nil)
                    .lineSpacing(4)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .onHover { hovering in
                        if hovering {
                            dismissTask?.cancel()
                        } else {
                            scheduleDismiss()
                        }
                    }
            }
            .onDisappear { dismissTask?.cancel() }
    }

    private func showPopover() {
        dismissTask?.cancel()
        isPresented = true
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            isPresented = false
        }
    }
}

private struct HoverHintModifier: ViewModifier {
    let text: String
    @State private var isVisible = false
    @State private var revealTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                revealTask?.cancel()
                if hovering {
                    revealTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        isVisible = true
                    }
                } else {
                    isVisible = false
                }
            }
            .overlay(alignment: .top) {
                if isVisible {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(radius: 3, y: 1)
                        .offset(y: -31)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isVisible)
            .zIndex(isVisible ? 10 : 0)
            .onDisappear { revealTask?.cancel() }
    }
}

private extension View {
    func hoverHint(_ text: String) -> some View {
        modifier(HoverHintModifier(text: text))
    }
}
