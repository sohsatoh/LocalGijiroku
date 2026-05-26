import SwiftUI
import GijirokuCore

/// Edits a single session's `SummaryStyle` override (session-level scope).
struct SessionStyleSheet: View {
    let original: Session
    let onSave: (Session) -> Void
    let onCancel: () -> Void

    @State private var style: SummaryStyle

    init(session: Session, onSave: @escaping (Session) -> Void, onCancel: @escaping () -> Void) {
        self.original = session
        self.onSave = onSave
        self.onCancel = onCancel
        _style = State(initialValue: session.summaryStyle ?? SummaryStyle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.format("session.style_sheet_title", original.title))
                .font(.title3)
                .lineLimit(2)

            ScrollView {
                StyleEditor(
                    style: $style,
                    scopeLabel: L10n.string("style.session_label"),
                    caption: L10n.string("style.session_caption")
                )
            }
            .frame(maxHeight: 360)

            HStack {
                Spacer()
                Button(L10n.string("sheet.cancel")) { onCancel() }
                Button(L10n.string("sheet.save")) {
                    var s = original
                    s.summaryStyle = (style == SummaryStyle()) ? nil : style
                    onSave(s)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
    }
}
