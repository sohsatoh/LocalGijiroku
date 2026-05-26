import SwiftUI

@main
struct GijirokuTakerApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var library = LibraryModel.shared
    @State private var showingOnboarding = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(library)
                .frame(minWidth: 1260, minHeight: 720)
                .sheet(isPresented: $showingOnboarding) {
                    OnboardingView { showingOnboarding = false }
                }
                .onAppear {
                    if !SettingsModel.shared.onboardingCompleted {
                        showingOnboarding = true
                    }
                    if ProcessInfo.processInfo.environment["GIJIROKU_AUTOSTART"] == "1" {
                        appModel.startRecording()
                    }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button(L10n.string("onboarding.menu")) {
                    showingOnboarding = true
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
