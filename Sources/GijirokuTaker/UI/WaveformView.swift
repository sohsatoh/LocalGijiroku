import SwiftUI
import GijirokuCore

/// Sliding-window RMS level for one audio source. We keep a small ring of
/// recent RMS samples so the view can draw a scrolling bar waveform.
struct WaveformChannelState: Equatable {
    static let historyLength = 80   // ~8 s at 100 ms cadence
    var rmsHistory: [Float] = Array(repeating: 0, count: historyLength)
    var currentRMS: Float = 0

    mutating func ingest(_ rms: Float) {
        currentRMS = rms
        rmsHistory.append(rms)
        if rmsHistory.count > Self.historyLength {
            rmsHistory.removeFirst(rmsHistory.count - Self.historyLength)
        }
    }
}

struct WaveformPanel: View {
    let mic: WaveformChannelState
    let system: WaveformChannelState

    var body: some View {
        HStack(spacing: 12) {
            channelRow(label: "🎙️", color: .blue, state: mic)
            channelRow(label: "💻", color: .green, state: system)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }

    private func channelRow(label: String, color: Color, state: WaveformChannelState) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 14))
            WaveformCanvas(history: state.rmsHistory, color: color)
                .frame(height: 28)
                .frame(maxWidth: .infinity)
            Text(dbString(state.currentRMS))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }

    private func dbString(_ rms: Float) -> String {
        guard rms > 0 else { return "-∞ dB" }
        let db = 20 * log10(rms)
        return String(format: "%5.1f dB", db)
    }
}

private struct WaveformCanvas: View {
    let history: [Float]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard !history.isEmpty else { return }
            let barWidth = size.width / CGFloat(history.count)
            let mid = size.height / 2
            for (i, level) in history.enumerated() {
                let normalized = min(1.0, max(0.0, CGFloat(level) * 3.0))
                let h = max(1.0, normalized * size.height)
                let rect = CGRect(
                    x: CGFloat(i) * barWidth,
                    y: mid - h / 2,
                    width: max(1.0, barWidth - 1),
                    height: h
                )
                let opacity = 0.35 + (CGFloat(i) / CGFloat(history.count)) * 0.65
                ctx.fill(Path(rect), with: .color(color.opacity(opacity)))
            }
        }
        .background(Color.black.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
