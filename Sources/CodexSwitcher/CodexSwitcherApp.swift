import SwiftUI

@main
struct CodexSwitcherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 650)

        Settings {
            Form {
                Toggle("启用自动刷新", isOn: $model.automaticRefresh)
                HStack {
                    TextField("间隔", value: $model.refreshIntervalValue, format: .number)
                    Picker("单位", selection: $model.refreshIntervalUnit) {
                        Text("秒").tag("seconds")
                        Text("分钟").tag("minutes")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(20).frame(width: 360)
        }
    }
}
