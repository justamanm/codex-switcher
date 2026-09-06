import SwiftUI

@main
struct CodexSwitcherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environment(\.locale, model.appLanguage.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 650)

        Settings {
            Form {
                Picker(model.text("语言"), selection: $model.appLanguage) {
                    Text(model.text("跟随系统")).tag(AppLanguage.system)
                    Text("中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }
                Toggle(model.text("启用自动刷新"), isOn: $model.automaticRefresh)
                HStack {
                    TextField(model.text("间隔"), value: $model.refreshIntervalValue, format: .number)
                    Picker(model.text("单位"), selection: $model.refreshIntervalUnit) {
                        Text(model.text("秒")).tag("seconds")
                        Text(model.text("分钟")).tag("minutes")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(20).frame(width: 360)
            .environment(\.locale, model.appLanguage.locale)
        }
    }
}
