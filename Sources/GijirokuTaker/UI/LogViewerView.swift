import SwiftUI
import AppKit

/// Live tail of stderr output, accessible from the Help menu. Useful when the
/// app is launched from Finder (no terminal attached) and the developer needs
/// to see what's happening during a recording without restarting via `nohup`.
struct LogViewerView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var autoScroll = true
    @State private var filter: String = ""

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(8)
            Divider()
            logScroll
        }
        .frame(minWidth: 640, minHeight: 380)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Toggle(L10n.string("log.auto_scroll"), isOn: $autoScroll)
                .toggleStyle(.checkbox)
            TextField(L10n.string("log.filter_placeholder"), text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            Spacer()
            Text(L10n.format("log.entry_count_format", filteredEntries.count, store.entries.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(L10n.string("log.copy")) { copyAll() }
            Button(L10n.string("log.clear")) { store.clear() }
        }
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredEntries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.timeFormatter.string(from: entry.timestamp))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .leading)
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(colorFor(message: entry.message))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .id(entry.id)
                    }
                }
            }
            .onChange(of: store.entries.count) { _, _ in
                guard autoScroll, let last = filteredEntries.last?.id else { return }
                withAnimation(.linear(duration: 0.08)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var filteredEntries: [LogStore.Entry] {
        guard !filter.isEmpty else { return store.entries }
        return store.entries.filter { $0.message.localizedCaseInsensitiveContains(filter) }
    }

    private func colorFor(message: String) -> Color {
        let lower = message.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("crash") {
            return .red
        }
        if lower.contains("warn") {
            return .orange
        }
        return .primary
    }

    private func copyAll() {
        let text = filteredEntries
            .map { "\(Self.timeFormatter.string(from: $0.timestamp))  \($0.message)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
