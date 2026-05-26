import Foundation

/// "Best-effort" structural extractor for the kinds of LLM JSON output we
/// can't fix with prompt engineering alone. The standard parse pipeline used
/// strict Codable decoding, which is brittle: small models love to invent
/// shapes like `bullets: [{"1": "..."}, {"2": "..."}]` instead of
/// `bullets: ["...","..."]`, or to use alternative key names ("heading"
/// for "title", "points" for "bullets", etc.). Codable can't accommodate
/// that without exhaustive enum-based decoders, but a `JSONSerialization`
/// `Any` tree walked by hand can.
///
/// The coercer's job is "given any JSON tree, what's the best interpretation
/// as `[SectionDTO]` / `[EventDTO]`?". Returns empty array (not nil) when
/// the tree clearly doesn't contain anything to coerce — empty arrays are a
/// legitimate "LLM found nothing this round" signal.
public enum JSONCoercer {
    public struct SectionDTO: Equatable {
        public let title: String
        public let bullets: [String]
    }
    public struct EventDTO: Equatable {
        public let kind: String
        public let text: String
        public let owner: String?
        public let due: String?
        public let resolved: Bool
        public let resolution: String?
    }

    /// Coerce any JSON tree into `[SectionDTO]`. Accepts:
    ///   - `{"sections":[{"title":..., "bullets":[...]}, ...]}` (canonical)
    ///   - `[{"title":..., "bullets":[...]}, ...]` (top-level array)
    ///   - `{"title":..., "bullets":[...]}` (single bare section)
    ///   - bullets in any of the pathological shapes flattenToStrings handles.
    public static func coerceSections(_ root: Any) -> [SectionDTO] {
        var out: [SectionDTO] = []
        for dict in extractEntries(from: root, envelopeKeys: ["sections", "summary"], looseKeys: ["title", "heading", "name", "section"]) {
            guard let title = firstString(of: ["title", "heading", "name", "section"], in: dict) else { continue }
            let rawBullets = firstValue(of: ["bullets", "points", "items", "content", "details", "list"], in: dict)
            let bullets = rawBullets.map(flattenToStrings) ?? []
            out.append(.init(title: title, bullets: bullets))
        }
        return out
    }

    /// Coerce any JSON tree into `[SummaryUpdate]`. Accepts:
    ///   - `{"updates":[{"section":..., "bullets":[...]}, ...]}` (canonical)
    ///   - `[{"section":..., "bullets":[...]}, ...]` (top-level array)
    ///   - `{"section":..., "bullets":[...]}` (single bare update)
    /// Falls back to common aliases (`title` / `heading` for section,
    /// `points` / `items` for bullets) so a small model that drifts back
    /// toward the full-summary shape still parses.
    public static func coerceUpdates(_ root: Any) -> [SummaryUpdate] {
        var out: [SummaryUpdate] = []
        for dict in extractEntries(
            from: root,
            envelopeKeys: ["updates", "additions", "sections"],
            looseKeys: ["section", "title", "heading"]
        ) {
            guard let section = firstString(of: ["section", "title", "heading", "name"], in: dict) else { continue }
            let rawBullets = firstValue(of: ["bullets", "points", "items", "content"], in: dict)
            let bullets = rawBullets.map(flattenToStrings) ?? []
            // Empty-bullet updates are no-ops; drop them so applyUpdates
            // doesn't churn the summary with a header-only insertion.
            guard !bullets.isEmpty else { continue }
            out.append(SummaryUpdate(section: section, bullets: bullets))
        }
        return out
    }

    /// Coerce any JSON tree into `[EventDTO]`. Accepts:
    ///   - `{"events":[{"kind":..., "text":...}, ...]}`
    ///   - `[{"kind":..., "text":...}, ...]`
    ///   - single bare `{"kind":..., "text":...}` event
    public static func coerceEvents(_ root: Any) -> [EventDTO] {
        var out: [EventDTO] = []
        for dict in extractEntries(from: root, envelopeKeys: ["events", "items"], looseKeys: ["kind", "type"]) {
            guard let kindRaw = firstString(of: ["kind", "type", "category"], in: dict),
                  let text = firstString(of: ["text", "content", "body", "description", "value"], in: dict) else {
                continue
            }
            let owner = firstString(of: ["owner", "assignee", "responsible", "person"], in: dict)
            let due = firstString(of: ["due", "dueDate", "deadline", "by"], in: dict)
            let resolved = firstBool(of: ["resolved", "closed", "done", "answered"], in: dict) ?? false
            let resolution = firstString(of: ["resolution", "answer", "outcome", "conclusion"], in: dict)
            out.append(.init(
                kind: kindRaw, text: text, owner: owner, due: due,
                resolved: resolved, resolution: resolution
            ))
        }
        return out
    }

    private static func firstBool(of keys: [String], in dict: [String: Any]) -> Bool? {
        for key in keys {
            if let value = dict[key] as? Bool { return value }
            if let number = dict[key] as? NSNumber { return number.boolValue }
        }
        return nil
    }

    // MARK: - Helpers

    /// Find a list of dictionaries to interpret as entries. Tries:
    ///   1. top-level array;
    ///   2. envelope keys at the top-level object (`sections`, `events`, …);
    ///   3. the top-level object itself if it has any of the per-entry keys.
    private static func extractEntries(from root: Any, envelopeKeys: [String], looseKeys: [String]) -> [[String: Any]] {
        if let arr = root as? [Any] {
            return arr.compactMap { $0 as? [String: Any] }
        }
        if let obj = root as? [String: Any] {
            for key in envelopeKeys {
                if let arr = obj[key] as? [Any] {
                    return arr.compactMap { $0 as? [String: Any] }
                }
            }
            if looseKeys.contains(where: { obj[$0] != nil }) {
                return [obj]
            }
        }
        return []
    }

    private static func firstString(of keys: [String], in dict: [String: Any]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let number = dict[key] as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private static func firstValue(of keys: [String], in dict: [String: Any]) -> Any? {
        for key in keys {
            if let value = dict[key] { return value }
        }
        return nil
    }

    /// Flatten an arbitrarily-nested JSON value to its constituent strings.
    /// This is the key trick that absorbs LLM creativity around array-of-
    /// strings vs array-of-objects vs object-with-numbered-keys.
    public static func flattenToStrings(_ value: Any) -> [String] {
        if let str = value as? String {
            return str.isEmpty ? [] : [str]
        }
        if let number = value as? NSNumber {
            return [number.stringValue]
        }
        if let arr = value as? [Any] {
            return arr.flatMap(flattenToStrings)
        }
        if let dict = value as? [String: Any] {
            // Sort keys numerically when they look like ordered indices
            // ("1","2","10"), otherwise alphabetically — both preserve a
            // deterministic order without losing items.
            let sortedKeys = dict.keys.sorted { lhs, rhs in
                if let l = Int(lhs), let r = Int(rhs) { return l < r }
                return lhs < rhs
            }
            return sortedKeys.flatMap { flattenToStrings(dict[$0]!) }
        }
        return []
    }
}
