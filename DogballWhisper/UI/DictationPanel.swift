import AppKit
import Observation
import SwiftUI

/// A borderless, non-activating panel floating above every window. It must
/// never take focus: the whole point is that the app you were typing in stays
/// focused so the paste lands there.
@MainActor
final class DictationPanelController: DictationPresenting {
    private let panel: NSPanel
    private let model = PanelModel()
    private var dismissTimer: Timer?

    init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: PanelPositioner.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // .fullScreenAuxiliary is what lets this surface as an overlay on a
        // Space another app has taken into native full screen; without it,
        // dictating into a full-screen editor or browser shows no panel.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PanelRoot(model: model))
    }

    func present(state: DictationState, at location: CaretLocation, levels: [Float]) {
        guard state != .idle else { return }
        dismissTimer?.invalidate()
        model.state = state
        model.levels = levels

        let screen = screenContaining(location.rectQuartz) ?? NSScreen.main
        let origin = PanelPositioner.origin(
            panelSize: PanelPositioner.panelSize,
            caretRectQuartz: location.rectQuartz,
            screenFrame: screen?.visibleFrame ?? .zero,
            primaryScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// Called with a delay so error and notice text is readable before it goes.
    func dismiss(after delay: TimeInterval) {
        dismissTimer?.invalidate()
        guard delay > 0 else {
            panel.orderOut(nil)
            return
        }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        }
    }

    /// Levels arrive at ~30Hz during recording, separately from state changes.
    /// Skipped while the panel is hidden so a trailing sample after
    /// `dismiss(after:)` fires does not re-evaluate a hidden SwiftUI body.
    func updateLevels(_ levels: [Float]) {
        guard panel.isVisible else { return }
        model.levels = levels
    }

    /// AX rects are top-left origin, so flip before matching against screens.
    private func screenContaining(_ quartzRect: CGRect?) -> NSScreen? {
        guard let quartzRect, quartzRect != .zero,
              let primaryMaxY = NSScreen.screens.first?.frame.maxY
        else { return NSScreen.main }
        let point = CGPoint(x: quartzRect.midX, y: primaryMaxY - quartzRect.midY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}

@Observable
final class PanelModel {
    var state: DictationState = .idle
    var levels: [Float] = []
}

private struct PanelRoot: View {
    let model: PanelModel

    var body: some View {
        DictationPanelContent(state: model.state, levels: model.levels)
    }
}
