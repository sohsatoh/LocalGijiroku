import Foundation
import SwiftUI
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
        static let voiceProcessing = "voiceProcessing"
    }

    @AppStorage(Keys.whisperModel) var whisperModel: String = WhisperModelChoice.largeV3Turbo.rawValue
    @AppStorage(Keys.whisperLanguage) var whisperLanguage: String = WhisperLanguage.ja.rawValue
    @AppStorage(Keys.llmBackend) var llmBackendRaw: String = LLMBackend.mlx.rawValue
    @AppStorage(Keys.mlxModelID) var mlxModelID: String = "mlx-community/Qwen3-4B-4bit"
    @AppStorage(Keys.ollamaModelID) var ollamaModelID: String = "qwen2.5:7b"
    @AppStorage(Keys.summaryUpdateInterval) var summaryUpdateInterval: Double = 30
    // ScreenCaptureKit ベースに切替済み (Core Audio Taps は macOS 26 Tahoe で動かないため廃止)。
    // 初回利用時に「画面録画」権限プロンプトが出る。
    @AppStorage(Keys.captureSystemAudio) var captureSystemAudio: Bool = true
    @AppStorage(Keys.captureMicrophone) var captureMicrophone: Bool = true
    @AppStorage(Keys.preferredInputDeviceUID) var preferredInputDeviceUID: String = ""
    @AppStorage(Keys.ollamaBaseURL) var ollamaBaseURL: String = "http://127.0.0.1:11434"
    // Apple の VoiceProcessingIO を有効化すると、システム出力（スピーカー側の信号）
    // をリファレンスにマイク入力からエコーをキャンセルする。ヘッドホンでない会議で
    // 「スピーカーから出た相手の声」がマイクに回り込んで二重 transcript される
    // 問題の標準的な対策。副作用としてノイズ抑制と自動ゲイン制御も入る。
    @AppStorage(Keys.voiceProcessing) var voiceProcessingEnabled: Bool = true

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
    case largeV3Turbo = "large-v3-v20240930_626MB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "tiny (約 75MB、最速、精度低)"
        case .base: return "base (約 145MB)"
        case .small: return "small (約 470MB)"
        case .largeV3Turbo: return "large-v3-turbo (約 626MB、多言語推奨)"
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
        case .ja: return "日本語"
        case .en: return "English"
        case .auto: return "自動判定"
        }
    }
}
