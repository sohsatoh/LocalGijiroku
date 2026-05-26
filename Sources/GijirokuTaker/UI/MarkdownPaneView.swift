import SwiftUI

/// Renders the subset of Markdown produced by `MarkdownExport` — `#`, `##`,
/// `###`, `- bullet`, `_italic_`, blank-line spacing, plus inline emphasis
/// (`**bold**`, `*em*`, `` `code` ``, links). Anything more exotic falls
/// through as plain text via `AttributedString(markdown:)`.
struct MarkdownPaneView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                    render(block)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(for: level))
                .textSelection(.enabled)
                .padding(.top, level == 1 ? 4 : 2)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                Text(inline(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph(let text):
            Text(inline(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .blank:
            Spacer().frame(height: 4)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        default: return .headline
        }
    }

    private func inline(_ text: String) -> AttributedString {
        // `.inlineOnlyPreservingWhitespace` keeps the leading whitespace intact
        // for indented bullet continuation lines and tolerates partial syntax.
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(text)
    }

    // MARK: - Parser

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case paragraph(text: String)
        case blank
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var sawBlank = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Collapse consecutive blank lines into a single spacer.
                if !sawBlank, !blocks.isEmpty { blocks.append(.blank) }
                sawBlank = true
                continue
            }
            sawBlank = false

            if line.hasPrefix("### ") {
                blocks.append(.heading(level: 3, text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                blocks.append(.heading(level: 2, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                blocks.append(.heading(level: 1, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                blocks.append(.bullet(text: String(line.dropFirst(2))))
            } else {
                blocks.append(.paragraph(text: line))
            }
        }
        return blocks
    }
}
