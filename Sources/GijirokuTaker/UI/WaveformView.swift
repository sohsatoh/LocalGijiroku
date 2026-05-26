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
        HStack(spacing: 14) {
            channelRow(symbol: "mic.fill", tint: .blue, state: mic)
            channelRow(symbol: "speaker.wave.2.fill", tint: .green, state: system)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [
                    Color(NSColor.windowBackgroundColor).opacity(0.4),
                    Color(NSColor.windowBackgroundColor).opacity(0.2),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func channelRow(symbol: String, tint: Color, state: WaveformChannelState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            WaveformCanvas(history: state.rmsHistory, tint: tint)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
            Text(dbString(state.currentRMS))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
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
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            guard !history.isEmpty else { return }
            let barWidth = size.width / CGFloat(history.count)
            let mid = size.height / 2
            // Gradient fill, brighter toward the trailing (most recent) edge.
            let gradient = Gradient(colors: [tint.opacity(0.35), tint])
            for (i, level) in history.enumerated() {
                let normalized = min(1.0, max(0.0, CGFloat(level) * 3.0))
                let h = max(1.5, normalized * size.height)
                let rect = CGRect(
                    x: CGFloat(i) * barWidth,
                    y: mid - h / 2,
                    width: max(1.0, barWidth - 1.5),
                    height: h
                )
                let t = CGFloat(i) / CGFloat(max(history.count - 1, 1))
                let alpha = 0.45 + t * 0.55
                let color = gradient.stops.first!.color.opacity(alpha)
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(color.opacity(alpha))
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
