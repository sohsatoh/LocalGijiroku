import Foundation
import SwiftUI
import GijirokuCore
import GijirokuLLM

@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    private enum Keys {
        static let whisperModel = "whisperModel"
        static let whisperLanguage = "whisperLanguage"
        static let llmBackend = "llmBackend"
        static let mlxModelID = "mlxModelID"
        static let ollamaModelID = "ollamaModelID"
        static let summaryUpdateInterval = "summaryUpdateInterval"
        static let captureSystemAudio = "captureSystemAudio"
        static let captureMicrophone = "captureMicrophone"
        static let preferredInputDeviceUID = "preferredInputDeviceUID"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let vadEnabled = "vadEnabled"
        static let userSummaryStyleJSON = "userSummaryStyleJSON"
        static let diarizationEnabled = "diarizationEnabled"
        static let onboardingCompleted = "onboardingCompleted"
        static let appLanguage = "appLanguage"
        static let paneMarkdownMode = "paneMarkdownMode"
    }

    @AppStorage(Keys.whisperModel) var whisperModel: String = WhisperModelChoice.largeV3Turbo.rawValue
    @AppStorage(Keys.whisperLanguage) var whisperLanguage: String = WhisperLanguage.ja.rawValue
    @AppStorage(Keys.llmBackend) var llmBackendRaw: String = LLMBackend.mlx.rawValue
    // Default: Qwen3 4B Instruct (2507) 4bit (~2.5 GB). Instruction-tuned
    // Qwen3 variant with NO reasoning / `<think>` blocks, strong
    // multilingual, mlx-swift-lm compatible. Smaller first-Start download
    // than the previous Qwen2.5-7B default.
    @AppStorage(Keys.mlxModelID) var mlxModelID: String = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    @AppStorage(Keys.ollamaModelID) var ollamaModelID: String = "qwen2.5:7b"
    @AppStorage(Keys.summaryUpdateInterval) var summaryUpdateInterval: Double = 30
    // ScreenCaptureKit ベースに切替済み (Core Audio Taps は macOS 26 Tahoe で動かないため廃止)。
    // 初回利用時に「画面録画」権限プロンプトが出る。
    @AppStorage(Keys.captureSystemAudio) var captureSystemAudio: Bool = true
    @AppStorage(Keys.captureMicrophone) var captureMicrophone: Bool = true
    @AppStorage(Keys.preferredInputDeviceUID) var preferredInputDeviceUID: String = ""
    @AppStorage(Keys.ollamaBaseURL) var ollamaBaseURL: String = "http://127.0.0.1:11434"
    // WhisperKit の EnergyVAD を有効化するか。ON にすると無音箇所で
    // 区切られて議事録向きのセグメンテーションになる。録音環境が極端に
    // 静かで微小発声まで拾いたい場合のみ OFF にする。
    @AppStorage(Keys.vadEnabled) var vadEnabled: Bool = true
    /// Pyannote (SpeakerKit) ベースの話者分離を有効化するか。初回利用時に
    /// segmentation + embedding の CoreML モデル (~30MB) が DL される。
    /// ローリング窓ごとに diarize するので、Speaker ラベルは「同じ窓内」では
    /// 一貫するが、窓を跨ぐと別の人に再割当される可能性がある（v2 で
    /// 永続クラスタリングを検討）。
    @AppStorage(Keys.diarizationEnabled) var diarizationEnabled: Bool = false
    /// Tracks whether the first-launch onboarding sheet has been shown and
    /// dismissed. UI offers a menu command to re-show it later.
    @AppStorage(Keys.onboardingCompleted) var onboardingCompleted: Bool = false
    /// UI display language override. "system" follows the macOS preferred
    /// languages order; concrete codes ("ja", "en") force that `.lproj`
    /// sub-bundle. Changes apply immediately because views are re-identified
    /// off this value.
    @AppStorage(Keys.appLanguage) var appLanguage: String = AppLanguage.system.rawValue
    /// Switches the Summary / Events panes between the structured list view
    /// (default) and a Markdown rendering that mirrors the export format.
    /// Applied uniformly to both panes — one toggle, both views.
    @AppStorage(Keys.paneMarkdownMode) var paneMarkdownMode: Bool = false
    /// JSON-encoded user-level SummaryStyle. Stored via @AppStorage so SwiftUI
    /// views update reactively, accessed through `userSummaryStyle` accessors.
    @AppStorage(Keys.userSummaryStyleJSON) var userSummaryStyleJSON: String = ""

    var userSummaryStyle: SummaryStyle {
        guard !userSummaryStyleJSON.isEmpty,
              let data = userSummaryStyleJSON.data(using: .utf8),
              let style = try? JSONDecoder().decode(SummaryStyle.self, from: data) else {
            return SummaryStyle()
        }
        return style
    }

    func updateUserSummaryStyle(_ style: SummaryStyle) {
        guard let data = try? JSONEncoder().encode(style),
              let str = String(data: data, encoding: .utf8) else { return }
        userSummaryStyleJSON = str
    }

    var llmBackend: LLMBackend {
        get { LLMBackend(rawValue: llmBackendRaw) ?? .mlx }
        set { llmBackendRaw = newValue.rawValue }
    }

    var activeLLMModelID: String {
        switch llmBackend {
        case .mlx: return mlxModelID
        case .ollama: return ollamaModelID
        }
    }

    private init() {}
}

enum WhisperModelChoice: String, CaseIterable, Identifiable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"
    case largeV3 = "large-v3"
    case largeV3Turbo = "large-v3-v20240930_626MB"
    case largeV3Full = "large-v3-v20240930_949MB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return L10n.string("whisper.tiny")
        case .base: return L10n.string("whisper.base")
        case .small: return L10n.string("whisper.small")
        case .medium: return L10n.string("whisper.medium")
        case .largeV3: return L10n.string("whisper.large_v3")
        case .largeV3Turbo: return L10n.string("whisper.large_v3_turbo")
        case .largeV3Full: return L10n.string("whisper.large_v3_full")
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case ja
    case en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.string("settings.app_language.system")
        case .ja: return L10n.string("settings.app_language.ja")
        case .en: return L10n.string("settings.app_language.en")
        }
    }
}

enum WhisperLanguage: String, CaseIterable, Identifiable {
    case ja = "ja"
    case en = "en"
    case auto = "auto"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ja: return L10n.string("whisper.language.ja")
        case .en: return L10n.string("whisper.language.en")
        case .auto: return L10n.string("whisper.language.auto")
        }
    }
}
