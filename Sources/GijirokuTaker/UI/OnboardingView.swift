import SwiftUI
import GijirokuCore
import GijirokuLLM

/// First-launch onboarding sheet. Five steps:
/// 1. Welcome / privacy promise
/// 2. Permissions required
/// 3. LLM backend + model picker
/// 4. Audio capture settings (system / mic / AEC / diarization / language)
/// 5. Usage tips
struct OnboardingView: View {
    let onComplete: () -> Void

    @ObservedObject private var settings = SettingsModel.shared
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @State private var step = 0
    @State private var availableModels: [ModelInfo] = []
    @State private var modelsLoading = false

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 620, height: 560)
        .id(settings.appLanguage)
        .environment(\.locale, L10n.locale())
        .task { await loadModels() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcomeStep
        case 1: permissionsStep
        case 2: llmStep
        case 3: audioStep
        case 4: usageStep
        default: welcomeStep
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(loc: "onboarding.welcome.title")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(loc: "onboarding.welcome.subtitle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(loc: "onboarding.welcome.detail")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(L10n.string("onboarding.permissions.title"), systemImage: "lock.shield")
            Text(loc: "onboarding.permissions.detail")
                .font(.callout)
                .foregroundStyle(.secondary)

            permissionRow(
                systemImage: "mic.fill",
                name: L10n.string("onboarding.permissions.mic"),
                status: permissions.microphone,
                kind: .microphone,
                request: { Task { await permissions.requestMicrophone() } }
            )
            permissionRow(
                systemImage: "rectangle.on.rectangle",
                name: L10n.string("onboarding.permissions.screen"),
                status: permissions.screenRecording,
                kind: .screenRecording,
                request: { permissions.requestScreenRecording() }
            )
            permissionRow(
                systemImage: "bell.fill",
                name: L10n.string("onboarding.permissions.notifications"),
                status: permissions.notifications,
                kind: .notifications,
                request: { Task { await permissions.requestNotifications() } }
            )
            Spacer()
        }
        .task { await permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Refresh after the user grants in System Settings and tabs back.
            Task { await permissions.refresh() }
        }
    }

    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(L10n.string("onboarding.llm.title"), systemImage: "brain")
            Text(loc: "onboarding.llm.detail")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker(L10n.string("settings.backend"), selection: Binding(
                get: { settings.llmBackend },
                set: {
                    settings.llmBackend = $0
                    Task { await loadModels() }
                }
            )) {
                ForEach(LLMBackend.allCases) { backend in
                    Text(backendDisplay(backend)).tag(backend)
                }
            }
            .pickerStyle(.segmented)

            if settings.llmBackend == .mlx {
                Text(loc: "onboarding.llm.mlx_recommend")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(loc: "settings.ollama_caption")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker(L10n.string("settings.model"), selection: currentModelBinding) {
                if availableModels.isEmpty {
                    Text(modelsLoading ? L10n.string("settings.loading") : L10n.string("settings.no_models"))
                        .tag("")
                } else {
                    ForEach(availableModels) { model in
                        modelLabel(model).tag(model.id)
                    }
                }
            }

            if settings.llmBackend == .mlx {
                mlxDownloadStatus
                    .padding(.leading, 2)
            }

            Picker(L10n.string("settings.transcription_backend"), selection: Binding(
                get: { settings.transcriptionBackend },
                set: { settings.transcriptionBackend = $0 }
            )) {
                ForEach(TranscriptionBackend.allCases) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }

            // Language belongs here too — it affects the transcription engine
            // and is part of "what kind of meetings will you record".
            Picker(L10n.string("settings.language"), selection: $settings.whisperLanguage) {
                ForEach(WhisperLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            Spacer()
        }
        .task(id: prefetchKey) { triggerPrefetchIfNeeded() }
        .onChange(of: downloads.stateByModel) { _, _ in
            // Prefetch finished (or transitioned states) — re-scan the disk
            // so the picker's "Downloaded ✓" reflects reality.
            Task { await loadModels() }
        }
    }

    /// Inline status row beneath the model picker. Drives the user's
    /// expectation that they can press Next without waiting — the dispatch
    /// happens in `triggerPrefetchIfNeeded`, this is purely the readout.
    @ViewBuilder
    private var mlxDownloadStatus: some View {
        let state = downloads.state(for: settings.mlxModelID)
        switch state {
        case .idle:
            EmptyView()
        case .downloading(let f):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView(value: f)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text(L10n.format("onboarding.llm.download_in_progress_format", Int(f * 100)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(loc: "onboarding.llm.download_caption")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .completed:
            Label {
                Text(loc: "onboarding.llm.download_completed")
                    .font(.caption)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Label {
                Text(L10n.format("onboarding.llm.download_failed_format", message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Re-trigger key for the LLM step's prefetch dispatcher: any change in
    /// backend or selected mlx model id re-runs `triggerPrefetchIfNeeded`.
    private var prefetchKey: String {
        "\(settings.llmBackend.rawValue)|\(settings.mlxModelID)"
    }

    private func triggerPrefetchIfNeeded() {
        guard settings.llmBackend == .mlx else { return }
        let id = settings.mlxModelID
        guard !id.isEmpty else { return }
        downloads.prefetchMLX(id)
        // The picker's "isDownloaded" badge is computed from the snapshot taken
        // at loadModels(). Once a prefetch resolves we want the badge to flip
        // to green too — re-scan the disk asynchronously.
        Task {
            await loadModels()
        }
    }

    private var audioStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(L10n.string("onboarding.audio.title"), systemImage: "waveform")
            Text(loc: "onboarding.audio.detail")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle(L10n.string("settings.capture_system"), isOn: $settings.captureSystemAudio)
            Toggle(L10n.string("settings.capture_mic"), isOn: $settings.captureMicrophone)
            if settings.transcriptionBackend == .whisperKit {
                Toggle(L10n.string("settings.diarization"), isOn: $settings.diarizationEnabled)
            }

            Text(loc: "onboarding.audio.recommend")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Spacer()
        }
    }

    private var usageStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(L10n.string("onboarding.usage.title"), systemImage: "play.circle.fill")
            usageRow(number: 1, text: L10n.string("onboarding.usage.step_record"))
            usageRow(number: 2, text: L10n.string("onboarding.usage.step_project"))
            usageRow(number: 3, text: L10n.string("onboarding.usage.step_view"))
            usageRow(number: 4, text: L10n.string("onboarding.usage.step_finish"))

            Divider().padding(.vertical, 4)

            // Final confirmation block — quick recap of what the user just set
            // up. Helps catch "wait, I didn't grant screen recording" before
            // they hit Record and the first session is silent.
            Text(loc: "onboarding.recap.title")
                .font(.subheadline.bold())
            recapRow(label: L10n.string("onboarding.recap.permissions"), value: permissionRecap)
            recapRow(label: L10n.string("onboarding.recap.llm"), value: "\(backendDisplay(settings.llmBackend)) · \(settings.activeLLMModelID)")
            recapRow(label: L10n.string("onboarding.recap.audio"), value: audioRecap)
            Spacer()
        }
        .task { await permissions.refresh() }
    }

    private var permissionRecap: String {
        let mic = recapBadge(permissions.microphone)
        let scr = recapBadge(permissions.screenRecording)
        let notif = recapBadge(permissions.notifications)
        return "\(mic) \(L10n.string("onboarding.permissions.mic_short"))   \(scr) \(L10n.string("onboarding.permissions.screen_short"))   \(notif) \(L10n.string("onboarding.permissions.notifications_short"))"
    }

    private func recapBadge(_ status: PermissionsManager.Status) -> String {
        switch status {
        case .granted: return "✓"
        case .notDetermined: return "?"
        case .denied: return "✗"
        }
    }

    private var audioRecap: String {
        var parts: [String] = []
        if settings.captureSystemAudio { parts.append(L10n.string("settings.capture_system")) }
        if settings.captureMicrophone { parts.append(L10n.string("settings.capture_mic")) }
        parts.append(settings.transcriptionBackend.displayName)
        if settings.transcriptionBackend == .whisperKit, settings.diarizationEnabled {
            parts.append(L10n.string("settings.diarization"))
        }
        if parts.isEmpty { return "—" }
        return parts.joined(separator: " · ")
    }

    private func recapRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            stepIndicator
            Spacer()
            Button(L10n.string("onboarding.skip")) { complete() }
                .buttonStyle(.borderless)
            if step > 0 {
                Button(L10n.string("onboarding.back")) { step -= 1 }
            }
            Button(step == totalSteps - 1
                   ? L10n.string("onboarding.finish")
                   : L10n.string("onboarding.next")) {
                if step == totalSteps - 1 {
                    complete()
                } else {
                    step += 1
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Circle()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.bold())
        }
    }

    private func permissionRow(
        systemImage: String,
        name: String,
        status: PermissionsManager.Status,
        kind: PermissionsManager.Kind,
        request: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 26)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                permissionStatusBadge(status)
            }
            Spacer()
            permissionAction(status: status, kind: kind, request: request)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private func permissionStatusBadge(_ status: PermissionsManager.Status) -> some View {
        switch status {
        case .granted:
            Label(L10n.string("onboarding.permissions.status_granted"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .notDetermined:
            Label(L10n.string("onboarding.permissions.status_not_requested"), systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .denied:
            Label(L10n.string("onboarding.permissions.status_denied"), systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func permissionAction(
        status: PermissionsManager.Status,
        kind: PermissionsManager.Kind,
        request: @escaping () -> Void
    ) -> some View {
        switch status {
        case .granted:
            EmptyView()
        case .notDetermined:
            Button(L10n.string("onboarding.permissions.request"), action: request)
                .buttonStyle(.bordered)
        case .denied:
            Button(L10n.string("onboarding.permissions.open_settings")) {
                permissions.openSystemSettings(for: kind)
            }
            .buttonStyle(.bordered)
        }
    }

    private func usageRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(.tint)
            Text(text)
                .font(.body)
            Spacer()
        }
    }

    /// Picker items in macOS SwiftUI collapse complex layouts to the first
    /// `Text` — so size and tag chips placed in an HStack wouldn't actually
    /// be visible in the dropdown. We pack everything into a single string
    /// so size is reliably shown on every line.
    /// We re-resolve `isDownloaded` live so the ✓ flips on as soon as the
    /// prefetch completes — the snapshot one in `availableModels` lags.
    private func modelLabel(_ model: ModelInfo) -> some View {
        let live = MLXAvailableModelsProvider.isDownloaded(model.id)
            || downloads.state(for: model.id) == .completed
        return Text(ModelPickerLabel.string(for: model, isDownloadedOverride: live))
    }

    private func backendDisplay(_ backend: LLMBackend) -> String {
        switch backend {
        case .mlx: return L10n.string("llm.backend.mlx")
        case .ollama: return L10n.string("llm.backend.ollama")
        }
    }

    private var currentModelBinding: Binding<String> {
        switch settings.llmBackend {
        case .mlx:
            return Binding(get: { settings.mlxModelID }, set: { settings.mlxModelID = $0 })
        case .ollama:
            return Binding(get: { settings.ollamaModelID }, set: { settings.ollamaModelID = $0 })
        }
    }

    @MainActor
    private func loadModels() async {
        modelsLoading = true
        defer { modelsLoading = false }
        let provider: any AvailableModelsProvider
        switch settings.llmBackend {
        case .mlx: provider = MLXAvailableModelsProvider()
        case .ollama:
            let url = URL(string: settings.ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!
            provider = OllamaAvailableModelsProvider(baseURL: url)
        }
        availableModels = await provider.availableModels()
    }

    private func complete() {
        settings.onboardingCompleted = true
        onComplete()
    }
}
