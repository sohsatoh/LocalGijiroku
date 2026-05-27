import SwiftUI
import GijirokuCore

/// Visual taxonomy for the three meeting event kinds. Each gets a tint color
/// + SF Symbol that's reused for the kind chip, the leading icon, and the
/// section header in EventPane. Keeping this mapping in one place ensures
/// the live recording view, the saved-session view, and any future surfaces
/// (e.g. notifications) stay visually consistent.
enum EventKindStyle {
    static func tint(_ kind: MeetingEvent.Kind) -> Color {
        switch kind {
        case .agendaSuggestion: return .yellow
        case .question: return .orange
        case .decision: return .green
        case .action: return .blue
        }
    }

    static func symbol(_ kind: MeetingEvent.Kind) -> String {
        switch kind {
        case .agendaSuggestion: return "sparkles"
        case .question: return "questionmark.bubble.fill"
        case .decision: return "checkmark.seal.fill"
        case .action: return "bolt.fill"
        }
    }

    static func label(_ kind: MeetingEvent.Kind) -> String {
        switch kind {
        case .agendaSuggestion: return L10n.string("event.kind.agendaSuggestion")
        case .question: return L10n.string("event.kind.question")
        case .decision: return L10n.string("event.kind.decision")
        case .action: return L10n.string("event.kind.action")
        }
    }

    /// Display order used by EventPane's grouped layout. AI agenda
    /// proposals lead so the user sees "what we should also discuss"
    /// before the items the meeting actually produced.
    static let displayOrder: [MeetingEvent.Kind] = [.agendaSuggestion, .action, .decision, .question]
}

/// One row in the events pane. Renders a colored leading badge, the event
/// text, and (when present) owner / due-date metadata as small pills below.
struct EventCard: View {
    let event: MeetingEvent
    var fontSize: CGFloat = 13

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            kindBadge
            VStack(alignment: .leading, spacing: 6) {
                Text(event.text)
                    .font(.system(size: fontSize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // Resolved events stay in the list but are visually
                    // muted with a strikethrough so the reader sees "this
                    // was raised but is now closed" rather than us silently
                    // dropping history.
                    .strikethrough(event.resolved, color: .secondary)
                    .foregroundStyle(event.resolved ? Color.secondary : Color.primary)
                // Resolution text — only present when the LLM had an
                // explicit answer / outcome. Indented + tinted to read
                // as "this is the response to the line above".
                if let resolution = event.resolution, !resolution.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(EventKindStyle.tint(event.kind).opacity(0.7))
                        Text(resolution)
                            // Resolution reads as a sub-detail of the main
                            // event line; render at fontSize - 1 to keep
                            // the visual hierarchy clear at any chosen base.
                            .font(.system(size: max(10, fontSize - 1)))
                            .textSelection(.enabled)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if event.owner != nil || event.dueDate != nil || event.resolved {
                    HStack(spacing: 6) {
                        if let owner = event.owner {
                            metaPill(symbol: "person.fill", text: owner)
                        }
                        if let due = event.dueDate {
                            metaPill(symbol: "calendar", text: due)
                        }
                        if event.resolved {
                            metaPill(symbol: "checkmark", text: L10n.string("event.resolved"))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(EventKindStyle.tint(event.kind).opacity(event.resolved ? 0.04 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(EventKindStyle.tint(event.kind).opacity(0.20), lineWidth: 0.5)
        )
    }

    private var kindBadge: some View {
        ZStack {
            Circle()
                .fill(EventKindStyle.tint(event.kind).opacity(0.18))
            Image(systemName: EventKindStyle.symbol(event.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EventKindStyle.tint(event.kind))
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel(EventKindStyle.label(event.kind))
    }

    private func metaPill(symbol: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}
