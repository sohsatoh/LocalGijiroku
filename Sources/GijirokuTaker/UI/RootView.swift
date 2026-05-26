import SwiftUI
import GijirokuCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(library: library)
        } detail: {
            switch library.selection {
            case .live:
                RecordingView()
            case .session(let id):
                if let session = library.loadSession(id: id) {
                    SessionDetailView(session: session)
                } else {
                    ContentUnavailableView("セッションが見つかりません", systemImage: "exclamationmark.triangle")
                }
            }
        }
    }
}

struct RecordingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WaveformPanel(mic: model.micWaveform, system: model.systemWaveform)
            Divider()
            HSplitView {
                TranscriptPane(segments: model.transcript)
                    .frame(minWidth: 320)
                SummaryPane(summary: model.summary)
                    .frame(minWidth: 320)
                EventPane(events: model.events)
                    .frame(minWidth: 280)
            }
        }
        .navigationTitle("録音中")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(model.isRecording ? "Stop" : "Start") {
                if model.isRecording {
                    model.stopRecording()
                } else {
                    model.startRecording()
                }
            }
            .keyboardShortcut("r", modifiers: [.command])

            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 6) {
                Text("保存先:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("保存先", selection: Binding(
                    get: { library.activeProjectID },
                    set: { library.activeProjectID = $0 }
                )) {
                    Text("（未分類）").tag(UUID?.none)
                    ForEach(library.projects) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .disabled(model.isRecording)
            }

            Text(model.summaryModelDisplay)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

struct TranscriptPane: View {
    let segments: [TranscriptSegment]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(segments) { seg in
                        HStack(alignment: .top, spacing: 6) {
                            Text(icon(for: seg.source))
                            Text(seg.text)
                                .textSelection(.enabled)
                                .opacity(seg.isFinal ? 1.0 : 0.85)
                            Spacer()
                        }
                        .id(seg.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: segments.last?.id) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
    }

    private func icon(for source: AudioSource) -> String {
        source == .microphone ? "🎙️" : "💻"
    }
}

struct SummaryPane: View {
    let summary: CumulativeSummary

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if summary.sections.isEmpty {
                    Text("Summary will appear here as the meeting progresses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                ForEach(summary.sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.headline)
                        ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                Text(bullet)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                    Divider()
                }
            }
            .padding(8)
        }
    }
}

struct EventPane: View {
    let events: [MeetingEvent]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if events.isEmpty {
                    Text("Questions, decisions, and actions will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 6) {
                        Text(icon(for: event.kind))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.text)
                                .textSelection(.enabled)
                            if let owner = event.owner {
                                Text("owner / \(owner)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let due = event.dueDate {
                                Text("due / \(due)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    Divider()
                }
            }
            .padding(8)
        }
    }

    private func icon(for kind: MeetingEvent.Kind) -> String {
        switch kind {
        case .question: return "❓"
        case .decision: return "✅"
        case .action: return "⚡"
        }
    }
}
