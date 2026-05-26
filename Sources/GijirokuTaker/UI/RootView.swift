import SwiftUI
import GijirokuCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryModel
    @ObservedObject private var settings = SettingsModel.shared

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
        // Rebuild the entire window when the language override changes so
        // every L10n.string read in this view tree re-resolves against the
        // new `.lproj`. The environment locale piggybacks for SwiftUI's own
        // number/date formatting.
        .id(settings.appLanguage)
        .environment(\.locale, L10n.locale())
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
    @ObservedObject private var settings = SettingsModel.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WaveformPanel(
                mic: model.micWaveform,
                system: model.systemWaveform,
                micEnabled: settings.captureMicrophone,
                systemEnabled: settings.captureSystemAudio,
                onToggleMic: { model.setMicCaptureEnabled(!settings.captureMicrophone) },
                onToggleSystem: { model.setSystemCaptureEnabled(!settings.captureSystemAudio) }
            )
            Divider()
            HSplitView {
                TranscriptPane(
                    turns: TranscriptTurnGrouping.turns(
                        from: model.transcript,
                        liveTail: model.liveTail
                    ),
                    showDiarizationPlaceholder: model.diarizationEnabled
                )
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

            if model.diarizationEnabled {
                diarizationIndicator
            }

            Spacer()

            PaneViewModePicker()

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

    /// Pill showing diarization activity. While the speaker count is 0 we
    /// label it "analyzing" so the user knows SpeakerKit is still loading or
    /// hasn't seen enough audio yet — otherwise the absence of speaker
    /// badges feels like silent failure.
    private var diarizationIndicator: some View {
        let count = model.distinctSpeakerCount
        return HStack(spacing: 4) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.caption)
            Text(count == 0
                 ? L10n.string("recording.diarization_analyzing")
                 : L10n.format("recording.diarization_count_format", count))
                .font(.caption)
        }
        .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill((count == 0 ? Color.secondary : Color.accentColor).opacity(0.12))
        )
        .help(L10n.string("recording.diarization_help"))
    }
}

// MARK: - Panes

struct TranscriptPane: View {
    let turns: [TranscriptTurn]
    var showDiarizationPlaceholder: Bool = false

    var body: some View {
        PaneContainer(
            title: L10n.string("pane.transcript.title"),
            systemImage: "text.bubble",
            isEmpty: turns.isEmpty,
            emptyMessage: L10n.string("pane.transcript.placeholder"),
            emptySystemImage: "waveform.path"
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(turns) { turn in
                            TranscriptTurnBlock(
                                turn: turn,
                                showDiarizationPlaceholder: showDiarizationPlaceholder
                            )
                            .id(turn.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: turns.last?.id) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .bottom)
                    }
                }
                // Also nudge the scroll when the most recent turn just
                // gained tail text — otherwise long-running live tails
                // sit below the fold while the user can't see them grow.
                .onChange(of: turns.last?.liveTail?.text) { _, _ in
                    guard let id = turns.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

/// One Notion-style speaker turn: header line (speaker + time + source
/// hint) above a flowing prose body. No card chrome — the eye reads
/// continuous text and parses turns by the header, not by row borders.
/// Confirmed paragraphs render as full-weight body text, with the live
/// tail flowing inline as italicized secondary-color text at the end of
/// the final paragraph so the user sees the decoder writing in real time.
private struct TranscriptTurnBlock: View {
    let turn: TranscriptTurn
    let showDiarizationPlaceholder: Bool

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            paragraphs
        }
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(accentColor)
                .frame(width: 8, height: 8)
            if let speaker = turn.speaker {
                SpeakerBadge(label: speaker)
            } else if showDiarizationPlaceholder {
                SpeakerBadge(label: "nomatch")
            }
            Image(systemName: sourceSymbol)
                .font(.caption2)
                .foregroundStyle(sourceColor.opacity(0.85))
            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(Self.timeFormatter.string(from: turn.startTime))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// Render each confirmed paragraph as its own Text view so SwiftUI
    /// gives them real paragraph breaks. The live tail flows inline at
    /// the end of the LAST paragraph (so it reads as the same sentence
    /// continuing), unless the last paragraph already ended on a
    /// sentence terminator — then the tail starts its own italic line.
    @ViewBuilder
    private var paragraphs: some View {
        VStack(alignment: .leading, spacing: 8) {
            let confirmed = turn.paragraphs
            if confirmed.isEmpty {
                // No confirmed text yet — only the live tail. Render it
                // as a standalone italic line so first words show up
                // immediately without needing a confirmed paragraph
                // anchor.
                if let tail = turn.liveTail {
                    Text(tail.text)
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(confirmed.enumerated()), id: \.offset) { idx, paragraph in
                    let isLast = idx == confirmed.count - 1
                    if isLast, let tail = turn.liveTail {
                        composedLastParagraph(paragraph, tail: tail.text)
                    } else {
                        Text(paragraph)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.leading, 14) // align with the header's text baseline
    }

    /// Confirmed paragraph + inline italic live tail. If the paragraph
    /// already ends with a sentence terminator we add a soft space so
    /// the tail visually starts a new clause rather than mashing into
    /// the period.
    private func composedLastParagraph(_ paragraph: String, tail: String) -> some View {
        var combined = Text(paragraph)
        let needsSpace = !paragraph.isEmpty && tail.first?.isLetter == true && (paragraph.last?.isLetter == true || paragraph.last?.isPunctuation == true)
        let separator: String
        if paragraph.isEmpty {
            separator = ""
        } else if needsSpace {
            separator = " "
        } else {
            separator = ""
        }
        combined = combined + Text(separator + tail)
            .italic()
            .foregroundStyle(.secondary)
        return combined
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accentColor: Color {
        if let speaker = turn.speaker {
            return SpeakerPalette.color(for: speaker)
        }
        return sourceColor
    }

    private var sourceSymbol: String {
        turn.source == .microphone ? "mic.fill" : "speaker.wave.2.fill"
    }

    private var sourceColor: Color {
        turn.source == .microphone ? .blue : .green
    }
}

struct SummaryPane: View {
    let summary: CumulativeSummary
    @ObservedObject private var settings = SettingsModel.shared

    var body: some View {
        PaneContainer(
            title: L10n.string("pane.summary.title"),
            systemImage: "doc.text",
            isEmpty: summary.sections.isEmpty,
            emptyMessage: L10n.string("pane.summary.placeholder"),
            emptySystemImage: "doc.text.magnifyingglass"
        ) {
            if settings.paneMarkdownMode {
                MarkdownPaneView(markdown: MarkdownExport.summary(summary))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(summary.sections) { section in
                            SummarySectionCard(section: section)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
    }
}

private struct SummarySectionCard: View {
    let section: CumulativeSummary.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                    Text(bullet)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

struct EventPane: View {
    let events: [MeetingEvent]
    @ObservedObject private var settings = SettingsModel.shared

    var body: some View {
        PaneContainer(
            title: L10n.string("pane.events.title"),
            systemImage: "checklist",
            isEmpty: events.isEmpty,
            emptyMessage: L10n.string("pane.events.placeholder"),
            emptySystemImage: "checkmark.circle"
        ) {
            if settings.paneMarkdownMode {
                MarkdownPaneView(markdown: MarkdownExport.events(events))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(EventKindStyle.displayOrder, id: \.self) { kind in
                            let group = events.filter { $0.kind == kind }
                            if !group.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    eventGroupHeader(kind: kind, count: group.count)
                                    ForEach(group) { event in
                                        EventCard(event: event)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func eventGroupHeader(kind: MeetingEvent.Kind, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: EventKindStyle.symbol(kind))
                .font(.caption)
                .foregroundStyle(EventKindStyle.tint(kind))
            Text(EventKindStyle.label(kind))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(verbatim: "(\(count))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
        }
    }
}

// MARK: - Shared pane container

/// Standard chrome around each detail pane: a slim heading bar with an icon
/// and title, a divider, and either the content or a centered empty state.
/// Centralised so the three panes look like a cohesive set instead of three
/// independently-styled scroll views.
private struct PaneContainer<Content: View>: View {
    let title: String
    let systemImage: String
    let isEmpty: Bool
    let emptyMessage: String
    let emptySystemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))
            Divider()
            if isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: emptySystemImage)
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content()
            }
        }
    }
}

/// Segmented switch toggling Summary/Events panes between structured list view
/// and Markdown rendering. Bound directly to `SettingsModel.shared`, so the
/// preference persists and applies to both live recording and saved sessions.
struct PaneViewModePicker: View {
    @ObservedObject private var settings = SettingsModel.shared

    var body: some View {
        Picker("", selection: $settings.paneMarkdownMode) {
            Text(loc: "pane.view_mode.list").tag(false)
            Text(loc: "pane.view_mode.markdown").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(L10n.string("pane.view_mode.help"))
    }
}
