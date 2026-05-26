import SwiftUI
import GijirokuCore

/// Read-only view for a previously-saved session, mirroring the layout of the
/// live recording view (transcript / summary / events).
struct SessionDetailView: View {
    let session: Session

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                TranscriptPane(segments: session.transcript)
                    .frame(minWidth: 320)
                SummaryPane(summary: session.summary)
                    .frame(minWidth: 320)
                EventPane(events: session.events)
                    .frame(minWidth: 280)
            }
        }
        .navigationTitle(session.title)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading) {
                Text(session.title).font(.headline)
                Text(timeRangeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(session.transcript.count) セグメント · \(session.events.count) イベント")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var timeRangeString: String {
        let start = session.startedAt.formatted(date: .numeric, time: .shortened)
        if let end = session.endedAt {
            let durationSec = Int(end.timeIntervalSince(session.startedAt))
            let mins = durationSec / 60
            let secs = durationSec % 60
            return "\(start) · 録音時間 \(mins) 分 \(secs) 秒"
        }
        return start
    }
}
