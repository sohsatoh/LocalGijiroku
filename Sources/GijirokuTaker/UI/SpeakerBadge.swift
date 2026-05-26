import SwiftUI

/// Small color-coded chip showing a speaker label next to a transcript line.
/// Color is derived from the label's hash so the same speaker keeps the
/// same color across the session.
struct SpeakerBadge: View {
    let label: String

    private static let palette: [Color] = [
        .blue, .purple, .orange, .green, .pink, .teal, .indigo, .brown, .red, .mint,
    ]

    var body: some View {
        Text(displayLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(Color.white)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var displayLabel: String {
        // "speakerId(0)" のような description を「S0」みたいに省略して表示。
        if let id = parseSpeakerId(label) {
            return "S\(id)"
        }
        if label.lowercased().contains("nomatch") { return "?" }
        return label.prefix(4).description
    }

    private var color: Color {
        if let id = parseSpeakerId(label) {
            return Self.palette[abs(id) % Self.palette.count]
        }
        let h = abs(label.hashValue)
        return Self.palette[h % Self.palette.count]
    }

    private func parseSpeakerId(_ s: String) -> Int? {
        // SpeakerInfo.description は "speakerId(N)" の形が想定だが、念のため
        // 末尾の数字を取り出すロジックで広めにカバーする。
        let digits = s.reversed().prefix(while: { $0.isNumber || $0 == ")" })
            .reversed()
            .filter { $0.isNumber }
        guard let n = Int(String(digits)) else { return nil }
        return n
    }
}
