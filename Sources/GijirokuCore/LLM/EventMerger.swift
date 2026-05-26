import Foundation

/// Merges a freshly-extracted batch of `MeetingEvent`s into an existing list,
/// folding duplicates and upgrading entries when newer extractions add
/// detail (owner, due date) for an event that was already recorded.
///
/// Identity is keyed on `(kind, first-N-chars of normalized text)`. The
/// extractor tends to re-emit the same decision/action across multiple
/// summary cycles with minor wording shifts, so a fuzzy key keeps the
/// resulting list from ballooning.
public struct EventMerger {
    public struct Config: Sendable {
        public var keyPrefixLength: Int

        public init(keyPrefixLength: Int = 20) {
            self.keyPrefixLength = keyPrefixLength
        }
    }

    public let config: Config

    public init(config: Config = .init()) {
        self.config = config
    }

    public func merge(_ newEvents: [MeetingEvent], into existing: inout [MeetingEvent]) {
        for new in newEvents {
            let newKey = key(for: new)
            if let idx = existing.firstIndex(where: { key(for: $0) == newKey }) {
                existing[idx] = Self.merged(into: existing[idx], from: new)
            } else {
                existing.append(new)
            }
        }
    }

    public func key(for event: MeetingEvent) -> String {
        let normalized = Self.normalize(event.text)
        let prefix = String(normalized.prefix(config.keyPrefixLength))
        return "\(event.kind.rawValue)|\(prefix)"
    }

    /// Merges `incoming` into `current`, keeping the original `id` /
    /// `detectedAt` (so the UI ordering is stable) but adopting newly-known
    /// owner / due fields, the longer / more recent text, and any
    /// resolved=true status the LLM has assigned. Once an event is marked
    /// resolved it stays resolved — later re-emissions can't accidentally
    /// re-open it.
    static func merged(into current: MeetingEvent, from incoming: MeetingEvent) -> MeetingEvent {
        let text: String = {
            if incoming.text.count >= current.text.count { return incoming.text }
            return current.text
        }()
        // Resolution: take the latest non-empty one. If a later turn
        // refines the answer ("by Friday" → "by Friday EOD"), we want
        // the refinement to win.
        let resolution = incoming.resolution ?? current.resolution
        return MeetingEvent(
            id: current.id,
            kind: current.kind,
            text: text,
            owner: incoming.owner ?? current.owner,
            dueDate: incoming.dueDate ?? current.dueDate,
            detectedAt: current.detectedAt,
            resolved: current.resolved || incoming.resolved,
            resolution: resolution
        )
    }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "　", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .lowercased()
    }
}
