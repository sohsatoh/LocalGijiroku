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
                    segments: model.transcript,
                    liveTail: model.liveTail,
                    headings: model.headings,
                    showDiarizationPlaceholder: model.diarizationEnabled,
                    layoutMode: settings.transcriptLayoutMode,
                    fontSize: CGFloat(settings.paneFontSize)
                )
                    .frame(minWidth: 280, idealWidth: 360)
                SummaryPane(summary: model.summary, fontSize: CGFloat(settings.paneFontSize))
                    .frame(minWidth: 280, idealWidth: 360)
                EventPane(events: model.events, fontSize: CGFloat(settings.paneFontSize))
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

/// Two-mode transcript pane:
///   - `.rows`: pre-streaming-UI behaviour — every confirmed segment AND
///     the live tail slot per source render as separate boxed rows, with
///     italic / dimmed styling for unconfirmed text. This is what the
///     app shipped with at commit 9bb0828 and remains the default.
///   - `.turns`: Notion-style speaker turns + paragraph splits + inline
///     live tail. Opt-in via Settings → General.
struct TranscriptPane: View {
    let segments: [TranscriptSegment]
    let liveTail: [AudioSource: TranscriptSegment]
    var headings: [TranscriptHeading] = []
    var showDiarizationPlaceholder: Bool = false
    var layoutMode: TranscriptLayoutMode = .rows
    var fontSize: CGFloat = 13

    var body: some View {
        PaneContainer(
            title: L10n.string("pane.transcript.title"),
            systemImage: "text.bubble",
            isEmpty: isEmpty,
            emptyMessage: L10n.string("pane.transcript.placeholder"),
            emptySystemImage: "waveform.path"
        ) {
            switch layoutMode {
            case .rows:
                rowsBody
            case .turns:
                turnsBody
            }
        }
    }

    private var isEmpty: Bool {
        switch layoutMode {
        case .rows: return rowSegments.isEmpty
        case .turns: return turns.isEmpty
        }
    }

    /// Confirmed transcript + live tails per source, sorted by time, so
    /// the rows layout renders the rolling tail as its own row in
    /// chronological place.
    private var rowSegments: [TranscriptSegment] {
        var combined = segments
        combined.append(contentsOf: liveTail.values)
        combined.sort { $0.startTime < $1.startTime }
        return combined
    }

    private var turns: [TranscriptTurn] {
        TranscriptTurnGrouping.turns(from: segments, liveTail: liveTail, headings: headings)
    }

    /// Interleave headings with segments (rows mode), sorted by
    /// `startTime`. Heading items get a stable identity tied to their
    /// UUID so SwiftUI diffs cleanly when a new heading slips into the
    /// middle of the list.
    private var rowItems: [TranscriptItem] {
        var items: [TranscriptItem] = headings.map { .heading($0) }
        items.append(contentsOf: rowSegments.map { .segment($0) })
        items.sort { $0.sortTime < $1.sortTime }
        return items
    }

    /// Same idea for the turns layout — headings slot between turns by
    /// `startTime`, so they read as section dividers in the speaker-turn
    /// prose flow.
    private var turnItems: [TranscriptItem] {
        var items: [TranscriptItem] = headings.map { .heading($0) }
        items.append(contentsOf: turns.map { .turn($0) })
        items.sort { $0.sortTime < $1.sortTime }
        return items
    }

    private var rowsBody: some View {
        let items = rowItems
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        rowItemView(item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: items.last?.id) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func rowItemView(_ item: TranscriptItem) -> some View {
        switch item {
        case .heading(let h):
            TranscriptHeadingRow(heading: h, fontSize: fontSize)
        case .segment(let seg):
            TranscriptRow(
                segment: seg,
                showDiarizationPlaceholder: showDiarizationPlaceholder,
                fontSize: fontSize
            )
        case .turn:
            // Unused in the rows layout — rowItems only mixes headings
            // with segments. Switch is exhaustive so the compiler keeps
            // both layouts honest about which item kinds they emit.
            EmptyView()
        }
    }

    private var turnsBody: some View {
        let items = turnItems
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(items) { item in
                        turnItemView(item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: items.last?.id) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
            .onChange(of: items.compactMap(\.turnLiveTailText).last) { _, _ in
                guard let id = items.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func turnItemView(_ item: TranscriptItem) -> some View {
        switch item {
        case .heading(let h):
            TranscriptHeadingRow(heading: h, fontSize: fontSize)
        case .turn(let turn):
            TranscriptTurnBlock(
                turn: turn,
                showDiarizationPlaceholder: showDiarizationPlaceholder,
                fontSize: fontSize
            )
        case .segment:
            EmptyView()
        }
    }
}

/// Internal flat item used by TranscriptPane to interleave headings with
/// either segments (rows mode) or turns (turns mode) under one
/// chronologically sorted ForEach.
private enum TranscriptItem: Identifiable {
    case heading(TranscriptHeading)
    case segment(TranscriptSegment)
    case turn(TranscriptTurn)

    var id: AnyHashable {
        switch self {
        case .heading(let h): return AnyHashable("heading-\(h.id.uuidString)")
        case .segment(let s): return AnyHashable("seg-\(s.id.uuidString)")
        case .turn(let t): return AnyHashable("turn-\(t.id.uuidString)")
        }
    }

    var sortTime: Date {
        switch self {
        case .heading(let h): return h.startTime
        case .segment(let s): return s.startTime
        case .turn(let t): return t.startTime
        }
    }

    /// Surface the unconfirmed-tail text only for turn items so the
    /// turns body can observe live-tail edits without exposing the
    /// rest of the case shape to the parent view.
    var turnLiveTailText: String? {
        if case .turn(let t) = self { return t.liveTail?.text }
        return nil
    }
}

/// Notion-style section divider: thin rule above + bold heading text.
/// Heading text comes from the LLM in the meeting's language and
/// scales with the user's pane font size, the same way speaker turn
/// text does.
private struct TranscriptHeadingRow: View {
    let heading: TranscriptHeading
    let fontSize: CGFloat

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.5)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(heading.text)
                    .font(.system(size: fontSize + 3, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Text(Self.timeFormatter.string(from: heading.startTime))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// Per-segment row used by the `.rows` transcript layout. Boxed card with
/// a colored left accent, speaker/source/time header, and italic + 0.55
/// opacity body when the segment is still in Whisper's rolling tail.
private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let showDiarizationPlaceholder: Bool
    let fontSize: CGFloat

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let speaker = segment.speaker {
                        SpeakerBadge(label: speaker)
                    } else if showDiarizationPlaceholder {
                        SpeakerBadge(label: "nomatch")
                    }
                    Image(systemName: sourceSymbol)
                        .font(.caption2)
                        .foregroundStyle(sourceColor)
                    Text(Self.timeFormatter.string(from: segment.startTime))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(segment.text)
                    .font(.system(size: fontSize))
                    .textSelection(.enabled)
                    // Unconfirmed (still in Whisper's rolling tail) — render
                    // dimmed and italic so the user sees the live stream
                    // but isn't surprised when the wording gets rewritten
                    // by the next inference pass.
                    .italic(!segment.isConfirmed)
                    .opacity(segment.isConfirmed ? 1.0 : 0.55)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accentColor.opacity(0.05))
        )
    }

    private var accentColor: Color {
        if let speaker = segment.speaker {
            return SpeakerPalette.color(for: speaker)
        }
        return sourceColor
    }

    private var sourceSymbol: String {
        segment.source == .microphone ? "mic.fill" : "speaker.wave.2.fill"
    }

    private var sourceColor: Color {
        segment.source == .microphone ? .blue : .green
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
    let fontSize: CGFloat

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
                        .font(.system(size: fontSize))
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
                            .font(.system(size: fontSize))
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
            .font(.system(size: fontSize))
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
    var fontSize: CGFloat = 13
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
                            SummarySectionCard(section: section, fontSize: fontSize)
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
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                // Header sits one point above the body so the visual
                // hierarchy stays intact regardless of the user's chosen
                // base size.
                .font(.system(size: fontSize + 1, weight: .semibold))
                .foregroundStyle(.primary)
            ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                    Text(bullet)
                        .font(.system(size: fontSize))
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
    var fontSize: CGFloat = 13
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
                                        EventCard(event: event, fontSize: fontSize)
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
