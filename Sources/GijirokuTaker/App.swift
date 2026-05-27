import SwiftUI
import AppKit

@main
struct GijirokuTakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
        Self.warmUpWhisper()
    }

    /// Kick off WhisperKit model loading in the background so the first
    /// recording doesn't pay the 15–20 s cold-load cost (which previously
    /// surfaced as "no transcript for the first 30 seconds"). The model is
    /// cached at module level by `WhisperModelCache` and reused across all
    /// sessions with the same config.
    private static func warmUpWhisper() {
        let modelName = SettingsModel.shared.whisperModel
        let vadEnabled = SettingsModel.shared.vadEnabled
        Task.detached(priority: .utility) {
            do {
                _ = try await WhisperModelCache.shared.loadModel(
                    name: modelName,
                    vadEnabled: vadEnabled,
                    vadEnergyThreshold: 0.02
                )
                fputs("[GijirokuTakerApp] Whisper preload finished model=\(modelName)\n", stderr)
            } catch {
                fputs("[GijirokuTakerApp] Whisper preload failed: \(error.localizedDescription)\n", stderr)
            }
        }
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
                    // Wire the live AppModel into the AppDelegate so the
                    // Cmd+Q hook can check `isAnyLLMTaskInFlight` and
                    // cancel in-flight tasks before NSApplication.terminate
                    // pulls the rug out from under MLX. Reset on view
                    // disappear so we don't keep a dangling reference if
                    // the window closes for any reason.
                    appDelegate.appModel = appModel
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

        // Menu-bar control that surfaces only while a recording is in flight.
        // Lets the user stop / pause without bringing the main window forward
        // — meeting use cases want the app out of the way while notes,
        // slides, etc. take focus.
        MenuBarExtra(
            isInserted: Binding(
                get: { appModel.isRecording },
                // The flag is driven by AppModel state, not user-toggleable
                // from here. macOS still calls the setter when the menu is
                // dismissed; ignore it.
                set: { _ in }
            )
        ) {
            MenuBarRecordingControls(appModel: appModel, openWindow: openWindow)
        } label: {
            // SF Symbols: pause.circle.fill while paused, record.circle.fill
            // while live. macOS tints the menu-bar icon based on the
            // template / palette config; .red fill carries through.
            Image(systemName: appModel.isPaused ? "pause.circle.fill" : "record.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(appModel.isPaused ? .yellow : .red, .primary)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// NSApplication delegate carved out so we can intercept Cmd+Q while
/// MLX work is in flight. Without this, SwiftUI's default termination
/// path calls `exit()` mid-Metal-command-buffer, and `~Scheduler()`
/// races with the still-running generate loop — surfacing as a SIGABRT
/// at `addCompletedHandler` on a tearing-down command buffer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `RootView.onAppear`. Held weakly to avoid retain cycles —
    /// the StateObject in the App outlives the delegate anyway, so the
    /// reference is "weak" mostly to express intent (this is a back
    /// channel, not ownership).
    weak var appModel: AppModel?

    /// Empirically chosen grace window: a 60-token title generation
    /// finishes in roughly 1–2 s on the smaller MLX models, so 3 s
    /// covers the most common in-flight Cmd+Q case without making the
    /// user wait noticeably long. Bigger regenerate turns may still
    /// race after this expires — the warning dialog has already told
    /// the user that's possible.
    private static let terminationGracePeriod: Duration = .seconds(3)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let appBusy = appModel?.isAnyLLMTaskInFlight ?? false
        let libBusy = LibraryModel.shared.isAnyLLMTaskInFlight
        guard appBusy || libBusy else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = L10n.string("quit.confirm.title")
        alert.informativeText = L10n.string("quit.confirm.message")
        alert.addButton(withTitle: L10n.string("quit.confirm.quit"))
        alert.addButton(withTitle: L10n.string("quit.confirm.cancel"))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        // Cancel the live recording's background tasks so MLX stops
        // taking new generate steps; existing in-flight steps will
        // complete naturally during the grace window. The autosaved
        // draft still represents the recording — DraftRecovery promotes
        // it on the next launch if persistFinalSession never ran.
        appModel?.prepareForTermination()

        Task { @MainActor in
            try? await Task.sleep(for: Self.terminationGracePeriod)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Compact control surface shown when the user clicks the menu-bar icon
/// during a recording. Status line, pause/resume, stop, and a shortcut to
/// bring the main app window forward.
private struct MenuBarRecordingControls: View {
    @ObservedObject var appModel: AppModel
    let openWindow: OpenWindowAction

    var body: some View {
        Text(appModel.isPaused
             ? L10n.string("menubar.paused")
             : L10n.string("menubar.recording"))
        Divider()
        if appModel.isPaused {
            Button(L10n.string("recording.resume")) {
                appModel.resumeRecording()
            }
        } else {
            Button(L10n.string("recording.pause")) {
                appModel.pauseRecording()
            }
        }
        Button(L10n.string("recording.stop")) {
            appModel.stopRecording()
        }
        .keyboardShortcut(".", modifiers: [.command, .shift])
        Divider()
        Button(L10n.string("menubar.show_window")) {
            // Bring the app to the foreground when the user wants to see
            // the live transcript / summary. macOS doesn't expose a
            // "focus the main window" intent from MenuBarExtra directly;
            // activating the app does the job.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
