import SwiftUI
import GijirokuCore
import GijirokuLLM

struct SettingsView: View {
    @ObservedObject private var settings = SettingsModel.shared
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var availableModels: [ModelInfo] = []
    @State private var modelsLoading = false

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
        .task { await refreshAll() }
    }

    private var generalTab: some View {
        Form {
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
        }
    }

    private var llmTab: some View {
        Form {
            Picker(L10n.string("settings.backend"), selection: Binding(
                get: { settings.llmBackend },
                set: { settings.llmBackend = $0; Task { await refreshModels() } }
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
                    Task { await refreshModels() }
                })
                Text(loc: "settings.ollama_caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(loc: "settings.mlx_caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
                    HStack {
                        Text(model.displayName)
                        if let tag = model.catalogTag {
                            Text(L10n.string("model.tag.\(tagKey(tag))"))
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        if let size = model.sizeEstimate {
                            Text("· \(size)")
                                .foregroundStyle(.secondary)
                        }
                        if model.isDownloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .tag(model.id)
                }
            }
        }
    }

    private func tagKey(_ tag: ModelTag) -> String {
        switch tag {
        case .lightweight: return "lightweight"
        case .default: return "default"
        case .multilingual: return "multilingual"
        case .highAccuracy: return "high_accuracy"
        case .largeMemory: return "large_memory"
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
            Toggle(L10n.string("settings.voice_processing"), isOn: $settings.voiceProcessingEnabled)
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
            Text(loc: "settings.voice_processing_caption")
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
