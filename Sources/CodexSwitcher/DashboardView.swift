import AppKit
import CodexSwitcherCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSettings = false
    private let accent = Color(red: 0.31, green: 0.57, blue: 0.39)

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader
                accountOverview
                if let error = model.lastError { errorCard(error) }
            }
            .padding(.horizontal, 44)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                accountsSection
                    .padding(.horizontal, 44)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
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
        .confirmationDialog(
            "切换账号",
            isPresented: $model.showingSwitchConfirmation,
            titleVisibility: .visible
        ) {
            Button("切换到 \(model.pendingSwitchAccount ?? "")") { model.confirmSwitch() }
            Button("取消", role: .cancel) { model.pendingSwitchAccount = nil }
        } message: {
            Text("请先保存 ChatGPT 中的内容。确认后会关闭 ChatGPT，切换账号，再自动重新打开 ChatGPT。")
        }
        .alert(
            "移除账号",
            isPresented: Binding(
                get: { model.removingAccount != nil },
                set: { if !$0 { model.removingAccount = nil } }
            )
        ) {
            Button("移到废纸篓", role: .destructive) { model.confirmRemove() }
            Button("取消", role: .cancel) { model.removingAccount = nil }
        } message: {
            Text("账号凭据将移到废纸篓，可以恢复；不会永久删除。")
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
        .task { model.start() }
    }

    private var pageHeader: some View {
        HStack(spacing: 16) {
            Text("Codex Switcher")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .help("打开设置")
            HStack(spacing: 7) {
                Circle().fill(model.lastError == nil ? .green : .orange).frame(width: 8, height: 8)
                Text("已载入 \(model.accounts.count) 个账号").foregroundStyle(.secondary)
            }
            .font(.callout)
            Spacer()
            Button { model.prepareAddAccount() } label: {
                Label("增加账号", systemImage: "person.badge.plus")
            }
            .controlSize(.large)
            .disabled(model.isSwitching)
            Button { model.refresh() } label: {
                Label(model.isRefreshing ? "正在刷新" : "刷新", systemImage: "arrow.clockwise")
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
                title: "当前使用",
                name: model.currentName.isEmpty ? "未识别" : model.displayName(for: model.currentName),
                identityHelp: model.identityHelp(for: model.currentName),
                account: model.accounts.first { $0.name == model.currentName },
                systemImage: model.currentType == "hub" ? "network" : "person.crop.circle.fill"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 80)

            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 54)

            if let account = model.recommendation {
                HStack(spacing: 14) {
                    overviewAccount(
                        title: "下一个账号",
                        name: model.displayName(for: account.name),
                        identityHelp: model.identityHelp(for: account.name),
                        account: account,
                        systemImage: "leaf.fill"
                    )
                    Button("切换") { model.requestSwitch(to: account.name) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isSwitching)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 80)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("下一个账号").font(.callout.weight(.semibold)).foregroundStyle(accent)
                    Text("暂无可用账号").font(.title3.bold())
                    Text("请刷新额度后重试").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 80)
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
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(accent)
                HoverAccountName(name: name, identityHelp: identityHelp, font: .title3.bold())
                if let account {
                    Text("5 小时 \(account.fiveHourRemaining)% · 周额度 \(account.weeklyRemaining)%")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("暂无额度信息").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("所有账号").font(.title3.bold())
                Text("\(model.accounts.count) 个").font(.callout).foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 10) {
                ForEach(model.rankedAccounts) { account in
                    AccountDashboardRow(
                        account: account,
                        displayName: model.displayName(for: account.name),
                        identityHelp: model.identityHelp(for: account.name),
                        isCurrent: model.currentType == "account" && model.currentName == account.name,
                        isRecommended: model.recommendation?.name == account.name,
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

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("设置", systemImage: "gearshape.fill").font(.title2.bold())
                Spacer()
                Button("完成") { showingSettings = false }.keyboardShortcut(.defaultAction)
            }
            Divider()
            Label("自动查询", systemImage: "clock.arrow.circlepath").font(.headline)
            HStack(spacing: 22) {
                Toggle("启用自动刷新", isOn: $model.automaticRefresh)
                    .toggleStyle(.switch)
                    .onChange(of: model.automaticRefresh) { _, _ in model.configureAutomaticRefresh() }
                Spacer()
                Text("查询间隔").foregroundStyle(.secondary)
                TextField("间隔", value: $model.refreshIntervalValue, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    .onChange(of: model.refreshIntervalValue) { _, value in
                        if value < 1 { model.refreshIntervalValue = 1 }
                        model.configureAutomaticRefresh()
                    }
                Picker("时间单位", selection: $model.refreshIntervalUnit) {
                    Text("秒").tag("seconds")
                    Text("分钟").tag("minutes")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .onChange(of: model.refreshIntervalUnit) { _, _ in model.configureAutomaticRefresh() }
            }
            Text("自动查询默认每 1 分钟执行；可自定义秒或分钟。全量查询时账号之间间隔 1 秒，单账号查询立即执行。")
                .font(.caption).foregroundStyle(.secondary)
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

    private var addAccountSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: model.isWaitingForLogin ? "person.crop.circle.badge.clock" : "person.badge.plus")
                .font(.system(size: 40)).foregroundStyle(accent)
            Text(model.isWaitingForLogin ? "等待新账号登录" : "增加 Codex 账号")
                .font(.title2.bold())
            Text(model.addAccountStage).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.isWaitingForLogin {
                ProgressView().controlSize(.large)
                Text("取消后会关闭 ChatGPT 应用。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("先保存并退出所有正在运行的 Codex CLI", systemImage: "terminal")
                    Label("继续后会关闭 ChatGPT 并保存当前账号", systemImage: "arrow.down.doc")
                    Label("重新登录后会自动识别用户名和邮箱", systemImage: "person.text.rectangle")
                }
                .font(.callout)
            }
            HStack {
                Spacer()
                Button(model.isCancellingLogin ? "正在恢复…" : "取消") { model.cancelLoginWatch() }
                    .disabled(model.isCancellingLogin)
                    .keyboardShortcut(.cancelAction)
                if !model.isAddingAccount {
                    Button("退出 ChatGPT 并继续") { model.startAddAccount() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(26).frame(width: 470)
    }

    private var aliasSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置账号别名").font(.title2.bold())
            Text("界面只显示别名；鼠标停留在别名上仍可查看原用户名和邮箱。")
                .foregroundStyle(.secondary)
            TextField("别名", text: $model.editingAlias)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { model.editingAccount = nil }
                Button("保存") { model.saveAlias() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 420)
    }
}

private struct AccountDashboardRow: View {
    @State private var showingActions = false
    private let accent = Color(red: 0.31, green: 0.57, blue: 0.39)
    let account: AccountUsage
    let displayName: String
    let identityHelp: String
    let isCurrent: Bool
    let isRecommended: Bool
    let isRefreshing: Bool
    let isSwitching: Bool
    let refreshAction: () -> Void
    let switchAction: () -> Void
    let aliasAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HoverAccountName(name: displayName, identityHelp: identityHelp, font: .title3.bold())
                .lineLimit(1)
                .frame(minWidth: 120, maxWidth: 210, alignment: .leading)
            if isCurrent { badge("当前", color: .green) }
            if isRecommended { badge("推荐", color: accent) }
            Text("更新于 \(formattedTimestamp(account.notedAt))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Divider().frame(height: 28)
            HorizontalQuota(title: "5 小时", value: account.fiveHourRemaining, reset: account.fiveHourReset)
            Divider().frame(height: 28)
            HorizontalQuota(title: "周额度", value: account.weeklyRemaining, reset: account.weeklyReset)
            Divider().frame(height: 28)
            Text("重置卡 \(account.resetCards) 张")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            accountActions
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isRecommended ? accent.opacity(0.38) : Color.secondary.opacity(0.16))
        )
    }

    private var accountActions: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { refreshAction() } label: {
                    ZStack {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 20, weight: .light))
                        }
                    }
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .hoverHint("立即查询此账号，不等待")
                .disabled(isRefreshing || isSwitching)

                Button { showingActions.toggle() } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20, weight: .light))
                        .frame(width: 32, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .hoverHint("账号操作")
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
                            Label("设置别名", systemImage: "pencil")
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
                            Label("移除账号", systemImage: "trash")
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
                Button("切换") { switchAction() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isSwitching)
            } else {
                Button(isCurrent ? "正在使用" : "切换") { switchAction() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isCurrent || isSwitching)
            }
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func formattedTimestamp(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct HorizontalQuota: View {
    let title: String
    let value: Int
    let reset: String

    private let accentDark = Color(red: 0.12, green: 0.30, blue: 0.18)
    private var color: Color { value == 0 ? .red : accentDark }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(value)%")
                .font(.title3.bold())
                .foregroundStyle(color)
            Text("重置 \(reset)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
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
                    .foregroundStyle(.primary)
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
