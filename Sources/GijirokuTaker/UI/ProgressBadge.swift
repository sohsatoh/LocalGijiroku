import SwiftUI

struct ProgressBadge: View {
    let progress: SummaryProgress

    var body: some View {
        HStack(spacing: 6) {
            if progress.isBusy {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 90)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            }
            Text(progress.displayText)
                .font(.caption)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var textColor: Color {
        switch progress {
        case .failed: return .red
        case .done: return .green
        case .idle: return .secondary
        default: return .secondary
        }
    }
}
