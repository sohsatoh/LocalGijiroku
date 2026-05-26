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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WaveformPanel(mic: model.micWaveform, system: model.systemWaveform)
            Divider()
            HSplitView {
                TranscriptPane(
                    segments: model.transcript,
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

            // Live mic / system-audio toggles. Tap mid-recording to mute
            // a source without stopping the session; tap again to bring
            // it back. Reflects + updates SettingsModel so the choice
            // persists into the next session.
            captureSourceToggles

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

    /// Side-by-side mic / system-audio toggle buttons. Tapping flips the
    /// AudioCaptureEngine's source on/off without stopping the session;
    /// the chosen state also persists into SettingsModel for next time.
    private var captureSourceToggles: some View {
        @ObservedObject var settings = SettingsModel.shared
        return HStack(spacing: 4) {
            captureToggleButton(
                isOn: settings.captureMicrophone,
                onSymbol: "mic.fill",
                offSymbol: "mic.slash.fill",
                tint: .blue,
                help: "recording.toggle_mic"
            ) {
                model.setMicCaptureEnabled(!settings.captureMicrophone)
            }
            captureToggleButton(
                isOn: settings.captureSystemAudio,
                onSymbol: "speaker.wave.2.fill",
                offSymbol: "speaker.slash.fill",
                tint: .green,
                help: "recording.toggle_system"
            ) {
                model.setSystemCaptureEnabled(!settings.captureSystemAudio)
            }
        }
    }

    private func captureToggleButton(
        isOn: Bool,
        onSymbol: String,
        offSymbol: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? onSymbol : offSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? tint : Color.secondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill((isOn ? tint : Color.secondary).opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(L10n.string(help))
    }
}

// MARK: - Panes

struct TranscriptPane: View {
    let segments: [TranscriptSegment]
    var showDiarizationPlaceholder: Bool = false

    var body: some View {
        PaneContainer(
            title: L10n.string("pane.transcript.title"),
            systemImage: "text.bubble",
            isEmpty: segments.isEmpty,
            emptyMessage: L10n.string("pane.transcript.placeholder"),
            emptySystemImage: "waveform.path"
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(segments) { seg in
                            TranscriptRow(segment: seg, showDiarizationPlaceholder: showDiarizationPlaceholder)
                                .id(seg.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onChange(of: segments.last?.id) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let showDiarizationPlaceholder: Bool

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 4px speaker accent on the left edge — same hue as the badge,
            // so a quick visual scan of the transcript shows who's talking
            // without reading every label. Falls back to a neutral track
            // when diarization is off or this segment is unlabeled.
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
                    .textSelection(.enabled)
                    .opacity(segment.isFinal ? 1.0 : 0.7)
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
        // No diarization label → use the source's color so the row still
        // gets a left-edge accent that differentiates mic vs. system audio.
        return sourceColor
    }

    private var sourceSymbol: String {
        segment.source == .microphone ? "mic.fill" : "speaker.wave.2.fill"
    }

    private var sourceColor: Color {
        segment.source == .microphone ? .blue : .green
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
