import SwiftUI
import GijirokuCore

/// Form fields for editing a `SummaryStyle`. Used at three scopes: user
/// (Settings), project (ProjectEditSheet), and session (SessionDetailView).
/// Empty / zero values mean "inherit from the next less-specific scope".
struct StyleEditor: View {
    @Binding var style: SummaryStyle
    let scopeLabel: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.format("style.scope_header_format", scopeLabel))
                .font(.headline)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(loc: "style.summary_extra_label")
                    .font(.subheadline)
                TextEditor(text: $style.extraSummaryInstructions)
                    .font(.body)
                    .frame(height: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text(loc: "style.summary_extra_example")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(loc: "style.event_extra_label")
                    .font(.subheadline)
                TextEditor(text: $style.extraEventInstructions)
                    .font(.body)
                    .frame(height: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text(loc: "style.event_extra_example")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                stepper(L10n.string("style.bullet_words_label"), value: $style.maxBulletWords, range: 0...60, zeroLabel: L10n.string("style.inherit_zero"))
                stepper(L10n.string("style.section_cap_label"), value: $style.maxSections, range: 0...20, zeroLabel: L10n.string("style.unlimited_zero"))
            }

            Text(loc: "style.inherit_caption")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, zeroLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption)
            Stepper(value: value, in: range) {
                Text(value.wrappedValue == 0 ? zeroLabel : "\(value.wrappedValue)")
                    .frame(width: 60, alignment: .leading)
            }
        }
    }
}
