import SwiftUI

/// Shared palette + label-shortening logic. Exposed so the transcript row's
/// left-side speaker accent bar uses the same color as the badge — the user
/// can scan the column to see who's talking without reading every label.
enum SpeakerPalette {
    static let colors: [Color] = [
        .blue, .purple, .orange, .green, .pink, .teal, .indigo, .brown, .red, .mint,
    ]

    static func color(for label: String) -> Color {
        if let id = parseID(label) {
            return colors[abs(id) % colors.count]
        }
        return colors[abs(label.hashValue) % colors.count]
    }

    static func shortLabel(_ label: String) -> String {
        if let id = parseID(label) {
            return "S\(id)"
        }
        if label.lowercased().contains("nomatch") { return "?" }
        return String(label.prefix(4))
    }

    private static func parseID(_ s: String) -> Int? {
        // SpeakerKit emits "speakerId(N)" style descriptions; tolerate other
        // shapes by pulling the trailing run of digits.
        let digits = s.reversed().prefix(while: { $0.isNumber || $0 == ")" })
            .reversed()
            .filter { $0.isNumber }
        return Int(String(digits))
    }
}

/// Color-coded chip showing a speaker label next to a transcript line. Color
/// is derived from the label's hash so the same speaker keeps the same color
/// across the session.
struct SpeakerBadge: View {
    let label: String

    var body: some View {
        Text(SpeakerPalette.shortLabel(label))
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color.white)
            .background(SpeakerPalette.color(for: label))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
