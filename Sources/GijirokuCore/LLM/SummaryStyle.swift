import Foundation

/// A piece of customization that nudges the LLM's summary and event-extraction
/// output. Applied as a 3-level hierarchy: built-in default → User → Project →
/// Session. Each level only overrides fields that are explicitly set
/// (non-empty string / positive number); empty / zero values inherit from the
/// less-specific level.
public struct SummaryStyle: Codable, Sendable, Equatable, Hashable {
    /// Free-form text appended to the system prompt for the summary engine.
    /// Use it for tone or focus instructions ("emphasize decisions",
    /// "ignore small talk", "always include acronym glossary", etc.)
    public var extraSummaryInstructions: String
    /// Free-form text appended to the system prompt for the event extractor.
    public var extraEventInstructions: String
    /// Max words per bullet. `0` means "inherit / use builtin (14)".
    public var maxBulletWords: Int
    /// Soft cap on the number of summary sections. `0` means "no cap".
    public var maxSections: Int
    /// Markdown template used when exporting a session. Empty string means
    /// "inherit / use MarkdownExporter's built-in default template".
    /// Supported placeholders are documented on `MarkdownExporter`.
    public var exportTemplate: String

    public init(
        extraSummaryInstructions: String = "",
        extraEventInstructions: String = "",
        maxBulletWords: Int = 0,
        maxSections: Int = 0,
        exportTemplate: String = ""
    ) {
        self.extraSummaryInstructions = extraSummaryInstructions
        self.extraEventInstructions = extraEventInstructions
        self.maxBulletWords = maxBulletWords
        self.maxSections = maxSections
        self.exportTemplate = exportTemplate
    }

    public static let builtin = SummaryStyle(
        extraSummaryInstructions: "",
        extraEventInstructions: "",
        maxBulletWords: 14,
        maxSections: 0,
        exportTemplate: ""
    )

    // Custom decoder so that JSON written before `exportTemplate` existed
    // (Projects / Sessions saved by an earlier build) still loads cleanly.
    private enum CodingKeys: String, CodingKey {
        case extraSummaryInstructions, extraEventInstructions
        case maxBulletWords, maxSections, exportTemplate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.extraSummaryInstructions = (try? c.decode(String.self, forKey: .extraSummaryInstructions)) ?? ""
        self.extraEventInstructions = (try? c.decode(String.self, forKey: .extraEventInstructions)) ?? ""
        self.maxBulletWords = (try? c.decode(Int.self, forKey: .maxBulletWords)) ?? 0
        self.maxSections = (try? c.decode(Int.self, forKey: .maxSections)) ?? 0
        self.exportTemplate = (try? c.decode(String.self, forKey: .exportTemplate)) ?? ""
    }

    /// Resolve order: builtin -> user -> project -> session. Each layer may
    /// be nil (= "no override"). Empty / zero fields inherit from below.
    public static func resolved(
        user: SummaryStyle? = nil,
        project: SummaryStyle? = nil,
        session: SummaryStyle? = nil
    ) -> SummaryStyle {
        builtin
            .merging(user)
            .merging(project)
            .merging(session)
    }

    public func merging(_ override: SummaryStyle?) -> SummaryStyle {
        guard let o = override else { return self }
        var r = self
        if !o.extraSummaryInstructions.isEmpty {
            r.extraSummaryInstructions = o.extraSummaryInstructions
        }
        if !o.extraEventInstructions.isEmpty {
            r.extraEventInstructions = o.extraEventInstructions
        }
        if o.maxBulletWords > 0 {
            r.maxBulletWords = o.maxBulletWords
        }
        if o.maxSections > 0 {
            r.maxSections = o.maxSections
        }
        if !o.exportTemplate.isEmpty {
            r.exportTemplate = o.exportTemplate
        }
        return r
    }
}
