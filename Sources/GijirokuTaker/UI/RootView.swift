import SwiftUI
import GijirokuCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(library: library)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            Group {
                if library.selection.count > 1 {
                    multiSelectionView
                } else if let single = library.singleSelection {
                    detailForSingle(single)
                } else {
                    ContentUnavailableView(L10n.string("error.session_select_prompt"), systemImage: "sidebar.left")
                }
            }
            .frame(minWidth: 960)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func detailForSingle(_ selection: LibrarySelection) -> some View {
        switch selection {
        case .live:
            RecordingView().id("live")
        case .session(let id):
            if let session = library.loadSession(id: id) {
                SessionDetailView(session: session).id(id)
            } else {
                ContentUnavailableView(L10n.string("error.session_not_found"), systemImage: "exclamationmark.triangle")
                    .id(id)
            }
        }
    }

    private var multiSelectionView: some View {
        let ids = library.selectedSessionIDs
        return VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L10n.format("error.multi_selected_count", ids.count))
                .font(.title3)
            Text(loc: "error.multi_selected_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(minWidth: 280, idealWidth: 360)
                SummaryPane(summary: model.summary)
                    .frame(minWidth: 280, idealWidth: 360)
                EventPane(events: model.events)
                    .frame(minWidth: 240, idealWidth: 280)
            }
        }
        .navigationTitle(L10n.string("recording.in_progress"))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                model.regenerateSummary()
            } label: {
                Label(loc: "recording.regenerate_summary", systemImage: "arrow.clockwise")
            }
            .disabled(model.transcript.isEmpty || model.summaryProgress.isBusy)
            .help(L10n.string("recording.regenerate_summary.help"))

            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressBadge(progress: model.summaryProgress)

            Spacer()

            HStack(spacing: 6) {
                Text(loc: "recording.save_destination")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L10n.string("recording.save_destination"), selection: Binding(
                    get: { library.activeProjectID },
                    set: { library.activeProjectID = $0 }
                )) {
                    Text(loc: "project.unfiled").tag(UUID?.none)
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
                            if let speaker = seg.speaker {
                                SpeakerBadge(label: speaker)
                            }
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
