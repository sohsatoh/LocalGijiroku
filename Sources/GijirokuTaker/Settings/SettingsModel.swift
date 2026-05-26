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
    }

    @AppStorage(Keys.whisperModel) var whisperModel: String = WhisperModelChoice.largeV3Turbo.rawValue
    @AppStorage(Keys.whisperLanguage) var whisperLanguage: String = WhisperLanguage.ja.rawValue
    @AppStorage(Keys.llmBackend) var llmBackendRaw: String = LLMBackend.mlx.rawValue
    @AppStorage(Keys.mlxModelID) var mlxModelID: String = "mlx-community/Qwen3-4B-4bit"
    @AppStorage(Keys.ollamaModelID) var ollamaModelID: String = "qwen2.5:7b"
    @AppStorage(Keys.summaryUpdateInterval) var summaryUpdateInterval: Double = 30
    // macOS 26 Tahoe では Core Audio Taps の IO callback が初回 1 frame で止まる
    // 不具合を確認しているため、デフォルトを OFF にしてマイク経路で動かす。
    // ScreenCaptureKit ベースの代替を将来実装する。
    @AppStorage(Keys.captureSystemAudio) var captureSystemAudio: Bool = false
    @AppStorage(Keys.captureMicrophone) var captureMicrophone: Bool = true
    @AppStorage(Keys.preferredInputDeviceUID) var preferredInputDeviceUID: String = ""
    @AppStorage(Keys.ollamaBaseURL) var ollamaBaseURL: String = "http://127.0.0.1:11434"

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
