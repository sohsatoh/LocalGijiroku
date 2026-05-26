import SwiftUI

@main
struct GijirokuTakerApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var library = LibraryModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(library)
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
