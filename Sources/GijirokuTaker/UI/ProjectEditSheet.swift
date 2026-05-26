import SwiftUI
import GijirokuCore

/// Edits a project's name and optional template (`SummaryStyle`) overrides.
/// Cannot be expressed cleanly as inline `@State` inside the parent sheet
/// closure, so it lives as its own view with its own state.
struct ProjectEditSheet: View {
    let original: Project
    let onSave: (Project) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var style: SummaryStyle

    init(project: Project, onSave: @escaping (Project) -> Void, onCancel: @escaping () -> Void) {
        self.original = project
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: project.name)
        _style = State(initialValue: project.summaryStyle ?? SummaryStyle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc: "sheet.project_edit_title").font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(loc: "sheet.project_name_label").font(.subheadline)
                TextField(L10n.string("sheet.project_name_placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            ScrollView {
                StyleEditor(
                    style: $style,
                    scopeLabel: L10n.string("style.project_label"),
                    caption: L10n.string("style.project_caption")
                )
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 360)

            HStack {
                Spacer()
                Button(L10n.string("sheet.cancel")) { onCancel() }
                Button(L10n.string("sheet.save")) {
                    var p = original
                    p.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    p.summaryStyle = (style == SummaryStyle()) ? nil : style
                    onSave(p)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 600)
    }
}
