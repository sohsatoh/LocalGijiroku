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
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(L10n.string("onboarding.permissions.title"), systemImage: "lock.shield")
            permissionRow(systemImage: "mic.fill", text: L10n.string("onboarding.permissions.mic"))
            permissionRow(systemImage: "rectangle.on.rectangle", text: L10n.string("onboarding.permissions.screen"))
            Text(loc: "onboarding.permissions.detail")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
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

            // Language belongs here too — it primarily affects Whisper but
            // is part of "what kind of meetings will you record".
            Picker(L10n.string("settings.language"), selection: $settings.whisperLanguage) {
                ForEach(WhisperLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            Spacer()
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
            Toggle(L10n.string("settings.voice_processing"), isOn: $settings.voiceProcessingEnabled)
            Toggle(L10n.string("settings.diarization"), isOn: $settings.diarizationEnabled)

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
            Spacer()
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

    private func permissionRow(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 24)
                .foregroundStyle(.tint)
            Text(text)
                .font(.body)
            Spacer()
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

    private func modelLabel(_ model: ModelInfo) -> some View {
        HStack {
            Text(model.displayName)
            if let tag = model.catalogTag {
                Text(L10n.string("model.tag.\(tag.rawValue.snakeCase)"))
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if let size = model.sizeEstimate {
                Text("· \(size)").foregroundStyle(.secondary)
            }
            if model.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
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

private extension String {
    /// `highAccuracy` → `high_accuracy` so it lines up with the strings table.
    var snakeCase: String {
        var result = ""
        for ch in self {
            if ch.isUppercase {
                if !result.isEmpty { result += "_" }
                result += String(ch).lowercased()
            } else {
                result.append(ch)
            }
        }
        return result
    }
}
