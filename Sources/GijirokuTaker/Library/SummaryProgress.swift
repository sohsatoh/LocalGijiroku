import Foundation

/// Coarse-grained progress state shared between AppModel (live recording
/// summary loop) and LibraryModel (past-session regeneration). The UI can
/// observe a single `@Published SummaryProgress` and render a status line +
/// determinate / indeterminate progress indicator from it.
enum SummaryProgress: Equatable, Sendable {
    case idle
    case modelDownloading(modelID: String, fraction: Double)
    case modelLoading(modelID: String)
    case summarizing(segmentCount: Int)
    case extractingEvents(segmentCount: Int)
    case generatingTitle
    case done(at: Date, sections: Int, events: Int)
    case failed(message: String)

    var isBusy: Bool {
        switch self {
        case .idle, .done, .failed: return false
        case .modelDownloading, .modelLoading, .summarizing, .extractingEvents, .generatingTitle:
            return true
        }
    }

    /// Determinate progress (0...1) when known, otherwise nil for indeterminate.
    var fraction: Double? {
        if case .modelDownloading(_, let f) = self { return f }
        return nil
    }

    var displayText: String {
        switch self {
        case .idle:
            return ""
        case .modelDownloading(let id, let f):
            return L10n.format("progress.model_downloading_format", Self.shortName(id), Int(f * 100))
        case .modelLoading(let id):
            return L10n.format("progress.model_loading_format", Self.shortName(id))
        case .summarizing(let n):
            return L10n.format("progress.summarizing_format", n)
        case .extractingEvents(let n):
            return L10n.format("progress.extracting_events_format", n)
        case .generatingTitle:
            return L10n.string("progress.generating_title")
        case .done(let at, let s, let e):
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return L10n.format("progress.done_format", f.string(from: at), s, e)
        case .failed(let msg):
            return L10n.format("progress.failed_format", msg)
        }
    }

    private static func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
