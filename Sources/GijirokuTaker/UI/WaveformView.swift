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
    let micEnabled: Bool
    let systemEnabled: Bool
    let onToggleMic: () -> Void
    let onToggleSystem: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            channelRow(
                onSymbol: "mic.fill",
                offSymbol: "mic.slash.fill",
                tint: .blue,
                state: mic,
                isEnabled: micEnabled,
                helpKey: "recording.toggle_mic",
                onTap: onToggleMic
            )
            channelRow(
                onSymbol: "speaker.wave.2.fill",
                offSymbol: "speaker.slash.fill",
                tint: .green,
                state: system,
                isEnabled: systemEnabled,
                helpKey: "recording.toggle_system",
                onTap: onToggleSystem
            )
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

    /// One channel row. The leading icon doubles as the source on/off
    /// toggle — clicking flips between `.fill` and `.slash.fill` SF Symbols
    /// and dims the waveform when off. Saves a separate toolbar control by
    /// folding the toggle into the existing visual element.
    private func channelRow(
        onSymbol: String,
        offSymbol: String,
        tint: Color,
        state: WaveformChannelState,
        isEnabled: Bool,
        helpKey: String,
        onTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: onTap) {
                Image(systemName: isEnabled ? onSymbol : offSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isEnabled ? tint : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string(helpKey))
            WaveformCanvas(history: state.rmsHistory, tint: tint)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .opacity(isEnabled ? 1.0 : 0.35)
            Text(dbString(state.currentRMS))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
                .opacity(isEnabled ? 1.0 : 0.5)
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
