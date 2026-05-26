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
        case .topic: return .purple
        case .question: return .orange
        case .decision: return .green
        case .action: return .blue
        }
    }

    static func symbol(_ kind: MeetingEvent.Kind) -> String {
        switch kind {
        case .topic: return "lightbulb.fill"
        case .question: return "questionmark.bubble.fill"
        case .decision: return "checkmark.seal.fill"
        case .action: return "bolt.fill"
        }
    }

    static func label(_ kind: MeetingEvent.Kind) -> String {
        switch kind {
        case .topic: return L10n.string("event.kind.topic")
        case .question: return L10n.string("event.kind.question")
        case .decision: return L10n.string("event.kind.decision")
        case .action: return L10n.string("event.kind.action")
        }
    }

    /// Display order used by EventPane's grouped layout. Topics come first
    /// so the user sees "what's being discussed" before "what to do about it".
    static let displayOrder: [MeetingEvent.Kind] = [.topic, .action, .decision, .question]
}

/// One row in the events pane. Renders a colored leading badge, the event
/// text, and (when present) owner / due-date metadata as small pills below.
struct EventCard: View {
    let event: MeetingEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            kindBadge
            VStack(alignment: .leading, spacing: 6) {
                Text(event.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if event.owner != nil || event.dueDate != nil {
                    HStack(spacing: 6) {
                        if let owner = event.owner {
                            metaPill(symbol: "person.fill", text: owner)
                        }
                        if let due = event.dueDate {
                            metaPill(symbol: "calendar", text: due)
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
                .fill(EventKindStyle.tint(event.kind).opacity(0.08))
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
