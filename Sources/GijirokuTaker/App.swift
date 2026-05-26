import SwiftUI

@main
struct GijirokuTakerApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var library = LibraryModel.shared
    @State private var showingOnboarding = false
    @Environment(\.openWindow) private var openWindow

    init() {
        // Hook stderr early so we don't miss the MLXClient init burst, the
        // first audio engine setup, or any startup error logged before the
        // user opens the Log Viewer.
        LogStore.shared.installStderrCapture()
        Self.migrateDeprecatedSettings()
    }

    /// One-shot rewrite of UserDefaults entries that point to MLX models we
    /// know don't load anymore (e.g. Gemma 3 — mlx-swift-lm 3.31 reads its
    /// grouped-query attention shape wrong and ensureLoaded throws). Without
    /// this, an existing user whose previous default was Gemma 3 would just
    /// see Start fail forever until they manually changed the picker.
    private static func migrateDeprecatedSettings() {
        let defaults = UserDefaults.standard
        let replacement = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        // Match by prefix so any quant variant of Gemma 3 is caught.
        let bannedPrefixes = ["mlx-community/gemma-3-"]
        if let current = defaults.string(forKey: "mlxModelID"),
           bannedPrefixes.contains(where: { current.hasPrefix($0) }) {
            defaults.set(replacement, forKey: "mlxModelID")
            fputs("[Settings] migrated incompatible mlxModelID \(current) → \(replacement)\n", stderr)
        }
    }

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
                Button(L10n.string("log.menu")) {
                    openWindow(id: "log-viewer")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Window(L10n.string("log.title"), id: "log-viewer") {
            LogViewerView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}
