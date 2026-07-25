import AppKit
import ApplicationServices

struct CaretLocation: Equatable {
    /// Caret rect in Quartz screen coordinates (origin top-left), or nil when
    /// the focused app does not report one.
    let rectQuartz: CGRect?
    let pid: pid_t?

    static let unknown = CaretLocation(rectQuartz: nil, pid: nil)
}

/// Asks the focused UI element where its insertion point is. Many Electron and
/// web apps answer nothing, which is expected: callers fall back to a fixed
/// panel position.
enum CaretLocator {
    static func current() -> CaretLocation {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard AXIsProcessTrusted() else { return CaretLocation(rectQuartz: nil, pid: frontPID) }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return CaretLocation(rectQuartz: nil, pid: frontPID) }
        let focused = focusedRef as! AXUIElement

        var elementPID: pid_t = 0
        AXUIElementGetPid(focused, &elementPID)
        let pid = elementPID != 0 ? elementPID : frontPID

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
            let range = rangeRef
        else { return CaretLocation(rectQuartz: nil, pid: pid) }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range,
            &boundsRef) == .success,
            let boundsValue = boundsRef
        else { return CaretLocation(rectQuartz: nil, pid: pid) }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.width >= 0 else {
            return CaretLocation(rectQuartz: nil, pid: pid)
        }
        return CaretLocation(rectQuartz: rect, pid: pid)
    }
}
