import CoreGraphics

/// Pure geometry, so the awkward part (AX reports top-left origins, Cocoa uses
/// bottom-left) is covered by tests instead of guesswork on screen.
enum PanelPositioner {
    static let panelSize = CGSize(width: 220, height: 56)
    static let caretGap: CGFloat = 10
    static let edgeInset: CGFloat = 8
    static let bottomInset: CGFloat = 120

    static func origin(
        panelSize: CGSize,
        caretRectQuartz: CGRect?,
        screenFrame: CGRect,
        primaryScreenMaxY: CGFloat
    ) -> CGPoint {
        guard let caret = caretRectQuartz, caret != .zero, caret.height > 0 else {
            return CGPoint(
                x: screenFrame.midX - panelSize.width / 2,
                y: screenFrame.minY + bottomInset
            )
        }

        let caretTopCocoa = primaryScreenMaxY - caret.minY
        let caretBottomCocoa = primaryScreenMaxY - caret.maxY

        var y = caretTopCocoa + caretGap
        if y + panelSize.height > screenFrame.maxY - edgeInset {
            y = caretBottomCocoa - panelSize.height - caretGap
        }
        y = min(max(y, screenFrame.minY + edgeInset), screenFrame.maxY - panelSize.height - edgeInset)

        let x = min(
            max(caret.midX - panelSize.width / 2, screenFrame.minX + edgeInset),
            screenFrame.maxX - panelSize.width - edgeInset
        )
        return CGPoint(x: x, y: y)
    }
}
