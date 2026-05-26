import SwiftUI
import GijirokuLLM

struct SettingsView: View {
    @ObservedObject private var settings = SettingsModel.shared
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var availableModels: [ModelInfo] = []
    @State private var modelsLoading = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("一般", systemImage: "gear") }
                .padding()
            llmTab
                .tabItem { Label("LLM", systemImage: "brain") }
                .padding()
            audioTab
                .tabItem { Label("オーディオ", systemImage: "waveform") }
                .padding()
            advancedTab
                .tabItem { Label("詳細", systemImage: "slider.horizontal.3") }
                .padding()
        }
        .frame(width: 600, height: 420)
        .task { await refreshAll() }
    }

    private var generalTab: some View {
        Form {
            Picker("文字起こしモデル", selection: $settings.whisperModel) {
                ForEach(WhisperModelChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
            }
            Picker("言語", selection: $settings.whisperLanguage) {
                ForEach(WhisperLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            Text("変更は次回の Start から有効になります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var llmTab: some View {
        Form {
            Picker("バックエンド", selection: Binding(
                get: { settings.llmBackend },
                set: { settings.llmBackend = $0; Task { await refreshModels() } }
            )) {
                ForEach(LLMBackend.allCases) { backend in
                    Text(backend.displayName).tag(backend)
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
                .help("モデル一覧を再読み込み")
            }

            if settings.llmBackend == .ollama {
                TextField("Ollama URL", text: $settings.ollamaBaseURL, onCommit: {
                    Task { await refreshModels() }
                })
                Text("Ollama サーバーが起動していて、モデルが pull 済みである必要があります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("初回選択時に HuggingFace から自動ダウンロードされます（数 GB、ネット接続必須）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelPicker: some View {
        Picker("モデル", selection: currentModelBinding) {
            if availableModels.isEmpty {
                Text(modelsLoading ? "読み込み中..." : "(該当モデルなし)").tag("")
            } else {
                ForEach(availableModels) { model in
                    HStack {
                        Text(model.displayName)
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
            Toggle("システム音声をキャプチャ", isOn: $settings.captureSystemAudio)
            Toggle("マイクをキャプチャ", isOn: $settings.captureMicrophone)

            HStack {
                Picker("入力デバイス", selection: $settings.preferredInputDeviceUID) {
                    Text("システムのデフォルト").tag("")
                    ForEach(inputDevices) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                Button("再読込") { refreshDevices() }
                    .buttonStyle(.borderless)
            }

            Text("システム音声タップは macOS 26 (Tahoe) で IO 不通の不具合あり。現在はマイク経由のキャプチャを推奨します（既知の制限、v2 で ScreenCaptureKit に置換予定）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedTab: some View {
        Form {
            Stepper(value: $settings.summaryUpdateInterval, in: 10...300, step: 5) {
                Text("サマリ更新間隔: \(Int(settings.summaryUpdateInterval)) 秒")
            }
            Text("短すぎると Ollama / MLX 推論が間に合わず重くなります。30〜60 秒推奨。")
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
