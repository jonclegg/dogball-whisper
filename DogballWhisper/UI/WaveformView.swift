import SwiftUI

/// Live level bars. Levels arrive newest-last, so the bars scroll leftward.
struct WaveformView: View {
    let levels: [Float]

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let minHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.primary.opacity(0.75))
                        .frame(
                            width: barWidth,
                            height: max(minHeight, CGFloat(level) * geometry.size.height)
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.linear(duration: 0.05), value: levels)
        }
    }
}

/// The panel's whole content: bars while recording, a line of text otherwise.
struct DictationPanelContent: View {
    let state: DictationState
    let levels: [Float]

    var body: some View {
        ZStack {
            switch state {
            case .recording:
                WaveformView(levels: levels)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
            case .transcribing:
                label("Transcribing…")
            case .polishing:
                label("Polishing…")
            case let .notice(message):
                label(message)
            case let .failed(message):
                label(message).foregroundStyle(.orange)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: PanelPositioner.panelSize.width, height: PanelPositioner.panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }
}
