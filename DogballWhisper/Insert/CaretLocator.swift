import AppKit
import ApplicationServices

struct CaretLocation: Equatable {
    /// Caret rect in Quartz screen coordinates (origin top-left), or nil when
    /// the focused app does not report one.
    let rectQuartz: CGRect?
    let pid: pid_t?
    /// True when the focused element is a secure/password text field.
    /// `DictationCoordinator` checks this before starting a recording:
    /// dictated text is sent to OpenRouter for cleanup, so recording into a
    /// password field would ship a password to a third party. This is kept
    /// distinct from `rectQuartz == nil` ("no caret found") on purpose —
    /// the two cases call for different behavior, not just different UI.
    let isSecureField: Bool

    init(rectQuartz: CGRect?, pid: pid_t?, isSecureField: Bool = false) {
        self.rectQuartz = rectQuartz
        self.pid = pid
        self.isSecureField = isSecureField
    }

    static let unknown = CaretLocation(rectQuartz: nil, pid: nil)
}

/// Asks the focused UI element where its insertion point is. Many Electron and
/// web apps answer nothing without help, which the nudge below addresses;
/// what remains after that is expected: callers fall back to a fixed panel
/// position.
///
/// Pipeline: root the query at the frontmost app (not the system-wide
/// element), nudge Chromium/Electron apps into building their accessibility
/// tree, descend from the reported focused element to the text leaf that
/// actually owns a selection, then try three tiers for the caret rect
/// (WebKit/Chromium text-marker range, AppKit selected-range bounds, the
/// focused element's own frame as a last resort).
enum CaretLocator {
    // PIDs already nudged into exposing their accessibility tree (see
    // `nudgeChromiumAXIfNeeded`). Read/written only from the main actor in
    // practice (`DictationCoordinator.begin()` is `@MainActor`), but this is
    // `static` state touched from a plain, non-isolated `enum`, so the lock
    // makes that safe rather than merely assumed.
    nonisolated(unsafe) private static var nudgedPIDs: Set<pid_t> = []
    private static let nudgedPIDsLock = NSLock()

    /// A real caret is a thin vertical bar; a rect this tall is a whole
    /// paragraph, document, or window instead of an insertion point, and
    /// would put the panel somewhere absurd. Tiers that report a rect
    /// claiming to *be* the caret (the text-marker and selected-range tiers)
    /// are rejected outside this band. The element-frame fallback does not
    /// need this check — see `caretRect(fromElementOrigin:size:)`.
    static let plausibleCaretHeightRange: ClosedRange<CGFloat> = 2...160

    static func isPlausibleCaretRect(_ rect: CGRect) -> Bool {
        plausibleCaretHeightRange.contains(rect.height)
    }

    static func current() -> CaretLocation {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp?.processIdentifier
        guard AXIsProcessTrusted() else { return CaretLocation(rectQuartz: nil, pid: frontPID) }
        guard let frontPID else { return .unknown }

        // Root the query at the frontmost app's own AX element rather than
        // `AXUIElementCreateSystemWide()`. The system-wide element answers
        // `kAXFocusedUIElementAttribute` from one shared, process-agnostic
        // notion of "the focused element" that a large class of apps —
        // notably Chromium- and WebKit-based ones — never populate; the same
        // attribute asked of the app's own `AXUIElementCreateApplication`
        // element reaches that app's own AX implementation directly and
        // actually answers. This one change is what fixes the common
        // "browser reports no caret" failure.
        let appElement = AXUIElementCreateApplication(frontPID)

        let justNudged = nudgeChromiumAXIfNeeded(appElement: appElement, pid: frontPID)

        var focusedRef: CFTypeRef?
        var focusErr = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if justNudged, focusErr != .success {
            // Chromium and Electron build their accessibility tree lazily,
            // starting only once the nudge above tells them to. Querying
            // immediately after a fresh nudge frequently lands before that
            // tree exists; one short sleep-and-retry usually gets past it,
            // and it only ever happens once per process (see the PID cache
            // in `nudgeChromiumAXIfNeeded`), not on every keystroke.
            Thread.sleep(forTimeInterval: 0.06)
            focusErr = AXUIElementCopyAttributeValue(
                appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        }
        // Bind the ref before asking for its type: `CFGetTypeID` takes an
        // implicitly unwrapped argument and traps on nil, and every failure
        // path in here is contracted to degrade to "no caret" instead.
        guard focusErr == .success,
            let focusedValue = focusedRef,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return CaretLocation(rectQuartz: nil, pid: frontPID) }
        var element = focusedValue as! AXUIElement

        var elementPID: pid_t = 0
        AXUIElementGetPid(element, &elementPID)
        let pid = elementPID != 0 ? elementPID : frontPID

        if isSecureField(element) {
            return CaretLocation(rectQuartz: nil, pid: pid, isSecureField: true)
        }

        // The reported focused element is frequently a container (an
        // AXWebArea, AXScrollArea, AXGroup, or even the window) rather than
        // the text leaf that actually owns the selection. Descend to find
        // one that does before trying any of the rect tiers below.
        if let leaf = descendToTextLeaf(from: element) {
            element = leaf
            // The leaf found by descending can turn out to be the secure
            // field even when the container it was found under did not
            // report itself as one.
            if isSecureField(element) {
                return CaretLocation(rectQuartz: nil, pid: pid, isSecureField: true)
            }
        }

        if let rect = caretRectViaTextMarker(element), isPlausibleCaretRect(rect) {
            return CaretLocation(rectQuartz: rect, pid: pid)
        }
        if let rect = caretRectViaSelectedRange(element), isPlausibleCaretRect(rect) {
            return CaretLocation(rectQuartz: rect, pid: pid)
        }
        if let rect = caretRectFromElementFrame(element) {
            return CaretLocation(rectQuartz: rect, pid: pid)
        }
        return CaretLocation(rectQuartz: nil, pid: pid)
    }

    // MARK: - Secure field detection

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        let subrole = copyStringAttribute(element, kAXSubroleAttribute as CFString)
        let role = copyStringAttribute(element, kAXRoleAttribute as CFString)
        return subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
    }

    // MARK: - Descend to the text leaf that actually owns a selection

    private static let textLeafRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXTextInput", "AXSearchField",
    ]
    /// Small on purpose: this only needs to reach past a handful of wrapper
    /// containers, not walk an app's entire view hierarchy.
    private static let maxDescendDepth = 6

    private static func hasSelectedTextRange(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success && raw != nil
    }

    /// Breadth-first search, preferring each node's own focused child, for
    /// the first descendant that reports a selected-text range. Returns nil
    /// (stay on `root`) when `root` already is a text leaf with a selection,
    /// or when nothing better is found within `maxDescendDepth`.
    private static func descendToTextLeaf(from root: AXUIElement) -> AXUIElement? {
        let rootRole = copyStringAttribute(root, kAXRoleAttribute as CFString) ?? ""
        if textLeafRoles.contains(rootRole) && hasSelectedTextRange(root) {
            return nil
        }

        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            if depth > 0 {
                let role = copyStringAttribute(node, kAXRoleAttribute as CFString) ?? ""
                if hasSelectedTextRange(node) && (textLeafRoles.contains(role) || role != rootRole) {
                    return node
                }
            }
            guard depth < maxDescendDepth else { continue }

            var focusedRaw: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                node, kAXFocusedUIElementAttribute as CFString, &focusedRaw) == .success,
                let next = focusedRaw, CFGetTypeID(next) == AXUIElementGetTypeID()
            {
                queue.append((next as! AXUIElement, depth + 1))
                continue
            }
            var childrenRaw: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                node, kAXChildrenAttribute as CFString, &childrenRaw) == .success,
                let children = childrenRaw as? [AXUIElement]
            {
                for child in children {
                    queue.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    // MARK: - Chromium / Electron AX opt-in

    @discardableResult
    private static func nudgeChromiumAXIfNeeded(appElement: AXUIElement, pid: pid_t) -> Bool {
        nudgedPIDsLock.lock()
        let alreadyNudged = nudgedPIDs.contains(pid)
        if !alreadyNudged { nudgedPIDs.insert(pid) }
        nudgedPIDsLock.unlock()
        guard !alreadyNudged else { return false }

        // Chromium- and Electron-based apps (Chrome, VS Code, Slack,
        // Discord, ...) do not build out their accessibility tree by
        // default: they only start doing so once something asks them to,
        // which is exactly why this class of app used to report nothing
        // here. Setting these two attributes on the *application* element
        // is that ask. It is a one-time opt-in per process — hence the PID
        // cache above — because re-setting it on every keystroke would just
        // be wasted cross-process IPC for no further effect.
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return true
    }

    // MARK: - Tier 1: WebKit / Chromium text-marker range
    //
    // `AXSelectedTextMarkerRange` and `AXBoundsForTextMarkerRange` have no
    // `kAX...`-style Swift constant anywhere in ApplicationServices; WebKit
    // and Chromium's accessibility trees only ever answer to these exact
    // string literals.

    private static func caretRectViaTextMarker(_ element: AXUIElement) -> CGRect? {
        var markerRangeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRangeRaw) == .success,
            let markerRange = markerRangeRaw
        else { return nil }

        var rectRaw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &rectRaw) == .success,
            let rectValue = rectRaw,
            CFGetTypeID(rectValue) == AXValueGetTypeID()
        else { return nil }

        var cgRect = CGRect.zero
        guard AXValueGetValue(rectValue as! AXValue, .cgRect, &cgRect), isFiniteRect(cgRect), cgRect.height > 0
        else { return nil }

        // This tier reports the bounds of the *selected range*, which for a
        // collapsed selection (the ordinary case: no text highlighted) can
        // come back zero-width at either edge. Anchor on the trailing edge
        // with an explicit hairline width rather than trusting the
        // reported width, which is frequently 0.
        return CGRect(x: cgRect.maxX, y: cgRect.minY, width: 1, height: cgRect.height)
    }

    // MARK: - Tier 2: AppKit AXBoundsForRange

    private static func caretRectViaSelectedRange(_ element: AXUIElement) -> CGRect? {
        var rangeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRaw) == .success,
            let range = rangeRaw
        else { return nil }

        var boundsRaw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsRaw) == .success,
            let boundsValue = boundsRaw,
            // The focused element belongs to another process's own AX
            // implementation, so its response can be malformed. Verify the
            // CFType before the force cast, same as the AXUIElement check
            // above: every failure path here must degrade to "no caret",
            // never trap.
            CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), isFiniteRect(rect), rect.height > 0
        else { return nil }
        return rect
    }

    // MARK: - Tier 3: the focused element's own frame

    private static func caretRectFromElementFrame(_ element: AXUIElement) -> CGRect? {
        var posRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRaw)
        _ = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw)

        var origin = CGPoint.zero
        if let posValue = posRaw, CFGetTypeID(posValue) == AXValueGetTypeID() {
            _ = AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        }
        var size = CGSize.zero
        if let sizeValue = sizeRaw, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            _ = AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        return caretRect(fromElementOrigin: origin, size: size)
    }

    /// Pure geometry, factored out of `caretRectFromElementFrame` so it can
    /// be unit tested without a real AX call.
    ///
    /// An element frame (a whole text field, or worse, a whole `AXWebArea`
    /// if descent never found a leaf) is not a caret and can be arbitrarily
    /// large in either dimension. Rather than validating it against the same
    /// `plausibleCaretHeightRange` tiers 1 and 2 are held to — which would
    /// throw this last-resort tier away entirely on exactly the giant-rect
    /// cases it exists to catch — this synthesizes a caret-sized sliver
    /// pinned to the frame's top-left corner. That lands close to the real
    /// insertion point (still far better than bottom-of-screen) and is
    /// always inside the plausible band by construction, so no separate
    /// rejection check is needed here.
    static func caretRect(fromElementOrigin origin: CGPoint, size: CGSize) -> CGRect? {
        guard origin.x.isFinite, origin.y.isFinite,
            size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0
        else { return nil }
        let height = min(max(size.height, 18), plausibleCaretHeightRange.upperBound)
        return CGRect(x: origin.x + 4, y: origin.y + 4, width: 1, height: height)
    }

    // MARK: - Small helpers

    private static func isFiniteRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.width >= 0 && rect.height >= 0
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }
}
