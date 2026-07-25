import SwiftUI

/// Live level bars. Levels arrive newest-last, so the bars scroll leftward.
struct WaveformView: View {
    let levels: [Float]

    private let barWidth: CGFloat = 1.5
    private let spacing: CGFloat = 1
    private let minHeight: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color(nsColor: .systemBlue))
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
                    .padding(.horizontal, 12)
                    .frame(height: 16)
            case .transcribing:
                label("Transcribing…").foregroundStyle(Color(nsColor: .systemBlue))
            case .polishing:
                label("Polishing…").foregroundStyle(Color(nsColor: .systemBlue))
            case let .notice(message):
                label(message)
            case let .failed(message):
                label(message).foregroundStyle(.orange)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: PanelPositioner.panelSize.width, height: PanelPositioner.panelSize.height)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }
}
