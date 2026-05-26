import SwiftUI

@main
struct GijirokuTakerApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    if ProcessInfo.processInfo.environment["GIJIROKU_AUTOSTART"] == "1" {
                        appModel.startRecording()
                    }
                }
        }

        Settings {
            SettingsView()
        }
    }
}
