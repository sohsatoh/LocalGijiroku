import SwiftUI
import GijirokuCore
import GijirokuLLM

struct SettingsView: View {
    @ObservedObject private var settings = SettingsModel.shared
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var availableModels: [ModelInfo] = []
    @State private var modelsLoading = false
    @State private var ollamaReachable: Bool? = nil

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(loc: "settings.tab.general", systemImage: "gear") }
                .padding()
            llmTab
                .tabItem { Label(loc: "settings.tab.llm", systemImage: "brain") }
                .padding()
            templateTab
                .tabItem { Label(loc: "settings.tab.templates", systemImage: "doc.text") }
                .padding()
            audioTab
                .tabItem { Label(loc: "settings.tab.audio", systemImage: "waveform") }
                .padding()
            advancedTab
                .tabItem { Label(loc: "settings.tab.advanced", systemImage: "slider.horizontal.3") }
                .padding()
        }
        .frame(width: 640, height: 560)
        // Re-identify the whole tab view when the language override changes so
        // SwiftUI rebuilds every Label/Picker title against the new `.lproj`.
        .id(settings.appLanguage)
        .environment(\.locale, L10n.locale())
        .task { await refreshAll() }
    }

    private var generalTab: some View {
        Form {
            Picker(L10n.string("settings.app_language"), selection: $settings.appLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            Text(loc: "settings.app_language.caption")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Picker(L10n.string("settings.transcription_model"), selection: $settings.whisperModel) {
                ForEach(WhisperModelChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
            }
            Picker(L10n.string("settings.language"), selection: $settings.whisperLanguage) {
                ForEach(WhisperLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            Text(loc: "settings.takes_effect_caption")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Picker(L10n.string("settings.transcript_layout"), selection: $settings.transcriptDisplayMode) {
                ForEach(TranscriptLayoutMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            Text(loc: "settings.transcript_layout.caption")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(loc: "settings.font_size")
                // Range 10–22 pt covers everything from "comfortable
                // glance" to "presentation mode". Stepper-style slider
                // keeps integer pt values predictable. Applied to the
                // transcript / summary / events panes uniformly.
                Slider(value: $settings.paneFontSize, in: 10...22, step: 1)
                Text(L10n.format("settings.font_size.value_format", settings.paneFontSize))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            Text(loc: "settings.font_size.caption")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var llmTab: some View {
        Form {
            Picker(L10n.string("settings.backend"), selection: Binding(
                get: { settings.llmBackend },
                set: { newValue in
                    settings.llmBackend = newValue
                    Task {
                        await refreshModels()
                        if newValue == .ollama { await pingOllama() }
                    }
                }
            )) {
                ForEach(LLMBackend.allCases) { backend in
                    Text(backendDisplay(backend)).tag(backend)
                }
            }

            HStack {
                modelPicker
                    .frame(maxWidth: .infinity)
                Button(action: { Task { await refreshModels() } }) {
                    if modelsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help(L10n.string("settings.refresh_models_help"))
            }

            if settings.llmBackend == .ollama {
                TextField(L10n.string("settings.ollama_url"), text: $settings.ollamaBaseURL, onCommit: {
                    Task {
                        await pingOllama()
                        await refreshModels()
                    }
                })
                ollamaStatusRow
                modelActionRow
                Text(loc: "settings.ollama_caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                modelActionRow
                Text(loc: "settings.mlx_caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Shows whether the configured Ollama URL is reachable + an "Install
    /// Ollama" link when it isn't. Polled on backend switch and after URL
    /// edits.
    @ViewBuilder
    private var ollamaStatusRow: some View {
        switch ollamaReachable {
        case .some(true):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(loc: "settings.ollama_reachable").font(.caption)
            }
        case .some(false):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc: "settings.ollama_unreachable").font(.caption)
                    Link(L10n.string("settings.ollama_install_link"),
                         destination: URL(string: "https://ollama.com/download")!)
                        .font(.caption2)
                }
            }
        case .none:
            EmptyView()
        }
    }

    /// Inline pull button + progress for the currently-selected model.
    /// MLX runs prefetch through the same manager so this works for both
    /// backends without duplicate UI.
    @ViewBuilder
    private var modelActionRow: some View {
        let id: String = {
            switch settings.llmBackend {
            case .mlx: return settings.mlxModelID
            case .ollama: return settings.ollamaModelID
            }
        }()
        let state = downloads.state(for: id)
        switch state {
        case .completed:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(loc: "settings.model_ready").font(.caption)
            }
        case .downloading(let f):
            HStack(spacing: 8) {
                ProgressView(value: f).progressViewStyle(.linear).frame(maxWidth: 220)
                Text(verbatim: "\(Int(f * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(L10n.format("settings.model_failed_format", msg))
                    .font(.caption2).foregroundStyle(.secondary)
                Button(L10n.string("settings.retry_pull")) { startDownload(id) }
            }
        case .idle:
            if !id.isEmpty {
                Button(action: { startDownload(id) }) {
                    Label(loc: "settings.pull_model", systemImage: "arrow.down.circle")
                }
                .disabled(settings.llmBackend == .ollama && ollamaReachable == false)
            }
        }
    }

    private func startDownload(_ modelID: String) {
        switch settings.llmBackend {
        case .mlx:
            downloads.prefetchMLX(modelID)
        case .ollama:
            let url = URL(string: settings.ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!
            downloads.pullOllama(modelID, baseURL: url)
        }
    }

    private func pingOllama() async {
        let url = URL(string: settings.ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!
        let client = OllamaClient(baseURL: url)
        ollamaReachable = await client.ping()
    }

    private func backendDisplay(_ backend: LLMBackend) -> String {
        switch backend {
        case .mlx: return L10n.string("llm.backend.mlx")
        case .ollama: return L10n.string("llm.backend.ollama")
        }
    }

    private var modelPicker: some View {
        Picker(L10n.string("settings.model"), selection: currentModelBinding) {
            if availableModels.isEmpty {
                Text(modelsLoading ? L10n.string("settings.loading") : L10n.string("settings.no_models")).tag("")
            } else {
                ForEach(availableModels) { model in
                    // Live disk check — keeps the ✓ flag accurate even when
                    // the cached `availableModels` snapshot is stale.
                    let live = model.backend == .mlx
                        ? MLXAvailableModelsProvider.isDownloaded(model.id)
                        : model.isDownloaded
                    Text(ModelPickerLabel.string(for: model, isDownloadedOverride: live)).tag(model.id)
                }
            }
        }
    }

    private var currentModelBinding: Binding<String> {
        switch settings.llmBackend {
        case .mlx:
            return Binding(
                get: { settings.mlxModelID },
                set: { settings.mlxModelID = $0 }
            )
        case .ollama:
            return Binding(
                get: { settings.ollamaModelID },
                set: { settings.ollamaModelID = $0 }
            )
        }
    }

    private var audioTab: some View {
        Form {
            Toggle(L10n.string("settings.capture_system"), isOn: $settings.captureSystemAudio)
            Toggle(L10n.string("settings.capture_mic"), isOn: $settings.captureMicrophone)
            Toggle(L10n.string("settings.vad"), isOn: $settings.vadEnabled)
            Toggle(L10n.string("settings.diarization"), isOn: $settings.diarizationEnabled)

            HStack {
                Picker(L10n.string("settings.input_device"), selection: $settings.preferredInputDeviceUID) {
                    Text(loc: "settings.input_default").tag("")
                    ForEach(inputDevices) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                Button(L10n.string("settings.reload")) { refreshDevices() }
                    .buttonStyle(.borderless)
            }

            Text(loc: "settings.system_audio_caption")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(loc: "settings.bleed_dedup_caption")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(loc: "settings.vad_caption")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(loc: "settings.diarization_caption")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var templateTab: some View {
        ScrollView {
            StyleEditor(
                style: Binding(
                    get: { settings.userSummaryStyle },
                    set: { settings.updateUserSummaryStyle($0) }
                ),
                scopeLabel: L10n.string("style.user_label"),
                caption: L10n.string("settings.template_caption")
            )
            .padding(.bottom, 16)
        }
    }

    private var advancedTab: some View {
        Form {
            Stepper(value: $settings.summaryUpdateInterval, in: 10...300, step: 5) {
                Text(L10n.format("settings.summary_interval_format", Int(settings.summaryUpdateInterval)))
            }
            Text(loc: "settings.summary_interval_caption")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func refreshAll() async {
        refreshDevices()
        await refreshModels()
        if settings.llmBackend == .ollama {
            await pingOllama()
        }
    }

    private func refreshDevices() {
        inputDevices = AudioInputDevices.list()
    }

    @MainActor
    private func refreshModels() async {
        modelsLoading = true
        defer { modelsLoading = false }
        let provider: any AvailableModelsProvider
        switch settings.llmBackend {
        case .mlx:
            provider = MLXAvailableModelsProvider()
        case .ollama:
            let url = URL(string: settings.ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!
            provider = OllamaAvailableModelsProvider(baseURL: url)
        }
        availableModels = await provider.availableModels()
    }
}
