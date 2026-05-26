import Foundation
import GijirokuLLM

/// Builds the single-line label used inside model `Picker` items in both
/// Onboarding and Settings. Combined into one `String` because SwiftUI's
/// macOS Picker only renders the first `Text` child per row — multi-element
/// HStack labels collapsed to just the display name, hiding size info that
/// the user actually wants to see at-a-glance.
enum ModelPickerLabel {
    /// Render a picker row for `model`. `isDownloadedOverride` lets callers
    /// pass a live disk check (preferred), falling back to whatever flag the
    /// snapshot ModelInfo was built with. This matters during onboarding
    /// where the cached `availableModels` array can lag behind the actual
    /// on-disk state until the next loadModels() call.
    static func string(for model: ModelInfo, isDownloadedOverride: Bool? = nil) -> String {
        var parts: [String] = [model.displayName]
        if let size = model.sizeEstimate {
            parts.append(size)
        }
        if let tag = model.catalogTag {
            parts.append("[\(L10n.string("model.tag.\(tagKey(tag))"))]")
        }
        if isDownloadedOverride ?? model.isDownloaded {
            parts.append("✓")
        }
        return parts.joined(separator: "  ·  ")
    }

    private static func tagKey(_ tag: ModelTag) -> String {
        switch tag {
        case .lightweight: return "lightweight"
        case .default: return "default"
        case .multilingual: return "multilingual"
        case .highAccuracy: return "high_accuracy"
        case .largeMemory: return "large_memory"
        }
    }
}
