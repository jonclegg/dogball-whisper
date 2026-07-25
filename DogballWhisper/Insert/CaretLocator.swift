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
            let boundsValue = boundsRef,
            // The focused element belongs to another process's own AX
            // implementation, so its response can be malformed. Verify the
            // CFType before the force cast, same as the AXUIElement check
            // above: every failure path here must degrade to "no caret",
            // never trap.
            CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return CaretLocation(rectQuartz: nil, pid: pid) }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else {
            return CaretLocation(rectQuartz: nil, pid: pid)
        }

        let isSaneRect = rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.width >= 0 && rect.height > 0
        guard isSaneRect else {
            return CaretLocation(rectQuartz: nil, pid: pid)
        }
        return CaretLocation(rectQuartz: rect, pid: pid)
    }
}
