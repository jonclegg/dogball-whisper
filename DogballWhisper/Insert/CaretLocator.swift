import AppKit
import ApplicationServices
import Carbon
import QuartzCore

struct CaretLocation: Equatable {
    /// Caret rect in Quartz screen coordinates (origin top-left), or nil when
    /// the focused app does not report one.
    let rectQuartz: CGRect?
    let pid: pid_t?
    /// True when the focused element is a secure/password text field, or when
    /// some app has secure event input engaged (a terminal password prompt,
    /// an authorization dialog).
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
/// Pipeline: refuse immediately if secure event input is engaged, root the
/// query at the frontmost app (not the system-wide element), descend from the
/// reported focused element to the text leaf that actually owns a selection,
/// then try three tiers for the caret rect (WebKit/Chromium text-marker range,
/// AppKit selected-range bounds, the focused element's own frame as a last
/// resort).
///
/// Everything here is bounded. Each of these calls is cross-process IPC into
/// an app that may be busy or wedged, and the whole thing runs on the main
/// actor while the user is already talking, so there is a messaging timeout
/// on every app element, and the tree walk has both a node budget and a
/// wall-clock deadline. Running out of any of them degrades to "no caret",
/// never to a stall.
enum CaretLocator {
    /// Wall-clock ceiling for a single cross-process AX request. Without it,
    /// one hung app blocks the main thread for seconds while the user is
    /// mid-sentence.
    static let messagingTimeout: Float = 0.05

    // Apps already nudged into exposing their accessibility tree (see
    // `nudge`), keyed by PID with the launch date as the value: PIDs are
    // recycled, and a newly launched Electron app landing on a recycled PID
    // must not be mistaken for one that has already been nudged. Terminated
    // apps are dropped by the observer in `startObservingAppSwitches()`; the
    // launch-date value is the belt-and-braces half of that, for a PID
    // recycled before the termination notification is processed.
    //
    // Touched from the main actor (`DictationCoordinator.begin()`) and from
    // `nudgeQueue`, so the lock is load-bearing rather than decorative.
    nonisolated(unsafe) private static var nudgedApps: [pid_t: Date] = [:]
    private static let nudgedAppsLock = NSLock()
    nonisolated(unsafe) private static var isObservingAppSwitches = false

    /// The nudge is cross-process IPC and never needs an answer, so it stays
    /// off the main thread entirely.
    private static let nudgeQueue = DispatchQueue(
        label: "com.jonclegg.DogballWhisper.CaretLocator.nudge", qos: .utility)

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

    /// Widest a reported rect can be and still plausibly *be* the caret, or
    /// the single character behind it.
    static let maxCaretLikeWidth: CGFloat = 25

    /// Collapse a reported text rect onto the insertion point.
    ///
    /// A collapsed selection usually comes back zero-width, and some
    /// implementations answer with the bounds of the character *preceding*
    /// the caret instead — in both of those cases the trailing edge is where
    /// the caret sits. But WebKit and Chromium frequently answer a collapsed
    /// marker range with the bounds of the whole line: measured in a browser
    /// compose box, w=427 for the same gesture that gives w=0 in a native
    /// text field. Anchoring such a rect on its trailing edge parks the panel
    /// at the field's right margin, far from the caret. Past about one
    /// character of width the rect is a line, not a caret, so the leading
    /// edge is the better guess.
    static func caretAnchor(for rect: CGRect) -> CGRect {
        let x = rect.width <= maxCaretLikeWidth ? rect.maxX : rect.minX
        return CGRect(x: x, y: rect.minY, width: 1, height: rect.height)
    }

    /// True when any app has secure event input engaged: a `sudo`/`ssh`/`gpg`
    /// prompt in a terminal, a `SecurityAgent` authorization dialog, a
    /// browser password field. This is the cheap half of the secure check —
    /// in-process, no accessibility permission needed, no IPC — and the only
    /// signal that catches terminal password prompts at all, since those are
    /// ordinary `AXTextArea`s with nothing secure about them as far as the
    /// accessibility tree is concerned.
    static func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    static func current() -> CaretLocation {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp?.processIdentifier

        // First, before any AX work: a password being typed anywhere is a
        // refusal no matter what the accessibility tree says.
        guard !isSecureInputActive() else {
            return CaretLocation(rectQuartz: nil, pid: frontPID, isSecureField: true)
        }

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
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        var focusedRef: CFTypeRef?
        var focusErr = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if focusErr != .success {
            // The failure itself is the signal that this app has not built
            // an accessibility tree, which is the only case that warrants
            // the nudge (see `nudge` for why it is not applied blindly).
            // Chromium and Electron build the tree lazily and asynchronously,
            // so the retry below usually still fails on this very first
            // press; the point of nudging here is the *next* press, and the
            // activation observer normally gets there first anyway. There is
            // deliberately no sleep-and-retry: this runs while the user is
            // already talking.
            if nudge(pid: frontPID, launchDate: frontApp?.launchDate, requireChromiumLikeBundle: false) {
                focusErr = AXUIElementCopyAttributeValue(
                    appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
            }
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
        switch descendToTextLeaf(from: element) {
        case .secure:
            // A password field found somewhere under the container that was
            // reported as focused. Every node the walk touches is checked,
            // not just the leaf it settles on.
            return CaretLocation(rectQuartz: nil, pid: pid, isSecureField: true)
        case .leaf(let leaf):
            element = leaf
        case .none:
            break
        }

        // Geometry only, never text: which tier answered and what it said is
        // the difference between a caret rect and a whole-line rect we
        // anchored at the wrong end, and that cannot be told apart from
        // outside the process.
        if let rect = caretRectViaTextMarker(element), isPlausibleCaretRect(rect) {
            Diagnostics.log("caret tier=textMarker rect=\(Diagnostics.describe(rect))")
            return CaretLocation(rectQuartz: rect, pid: pid)
        }
        if let rect = caretRectViaSelectedRange(element), isPlausibleCaretRect(rect) {
            Diagnostics.log("caret tier=selectedRange rect=\(Diagnostics.describe(rect))")
            return CaretLocation(rectQuartz: rect, pid: pid)
        }
        if let rect = caretRectFromElementFrame(element) {
            Diagnostics.log("caret tier=elementFrame rect=\(Diagnostics.describe(rect))")
            return CaretLocation(rectQuartz: rect, pid: pid)
        }
        Diagnostics.log("caret tier=none")
        return CaretLocation(rectQuartz: nil, pid: pid)
    }

    // MARK: - Secure field detection

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        // macOS reports this as a *subrole* (`AXSecureTextField`) on an
        // ordinary `AXTextField` role, in native apps and in WebKit/Chromium
        // for `input[type=password]` alike.
        copyStringAttribute(element, kAXSubroleAttribute as CFString)
            == (kAXSecureTextFieldSubrole as String)
    }

    // MARK: - Descend to the text leaf that actually owns a selection

    private static let textLeafRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXTextInput", "AXSearchField",
    ]
    /// Small on purpose: this only needs to reach past a handful of wrapper
    /// containers, not walk an app's entire view hierarchy.
    private static let maxDescendDepth = 6
    /// Depth alone does not bound the walk: a node that does not report a
    /// focused child contributes *all* of its children, and a real web area
    /// six levels deep is thousands of nodes, each costing cross-process
    /// round trips. This is the actual bound.
    static let maxDescendNodes = 48
    /// And this is the bound that matters when the app on the other end is
    /// slow rather than large. The user is already talking by the time this
    /// runs, so it is deliberately tight.
    static let maxDescendDuration: CFTimeInterval = 0.012
    /// No node needs more than a handful of siblings inspected; a container
    /// with hundreds of children is a list, not a text field's wrapper.
    private static let maxChildrenPerNode = 16

    private enum Descent {
        /// A better element than the root to ask for a caret rect.
        case leaf(AXUIElement)
        /// A password field was found during the walk: refuse the dictation.
        case secure
        /// Nothing better found (or the budget ran out): stay on the root.
        case none
    }

    private static func hasSelectedTextRange(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success && raw != nil
    }

    private static func isFocused(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedAttribute as CFString, &raw) == .success,
            let value = raw, CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRaw) == .success,
            // The one cast here that leans on the runtime's own element check
            // rather than a per-element `CFGetTypeID`: a bridged `as?` to
            // `[AXUIElement]` verifies every member and yields nil on any
            // mismatch, so a malformed answer degrades instead of trapping.
            // That is deliberate, not an oversight.
            let children = childrenRaw as? [AXUIElement]
        else { return [] }
        return children
    }

    /// Breadth-first search, preferring each node's own focused child, for
    /// the first descendant that reports a selected-text range. Returns
    /// `.none` (stay on `root`) when `root` already is a text leaf with a
    /// selection, when nothing better is found within the depth limit, or
    /// when the node budget or deadline runs out first.
    ///
    /// Every node it touches is also checked for being a password field:
    /// the container reported as focused frequently is not the secure leaf
    /// underneath it, and refusing has to win over positioning a panel.
    private static func descendToTextLeaf(from root: AXUIElement) -> Descent {
        let rootRole = copyStringAttribute(root, kAXRoleAttribute as CFString) ?? ""
        if textLeafRoles.contains(rootRole) && hasSelectedTextRange(root) {
            return .none
        }

        let deadline = CACurrentMediaTime() + maxDescendDuration
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        // An index cursor rather than `removeFirst()`, which is O(n) on an
        // Array and would make the walk quadratic in the node budget.
        var cursor = 0
        var budget = maxDescendNodes

        while cursor < queue.count {
            guard budget > 0, CACurrentMediaTime() < deadline else { return .none }
            budget -= 1
            let (node, depth) = queue[cursor]
            cursor += 1

            if depth > 0 {
                // `root` was already checked by the caller.
                if isSecureField(node) { return .secure }
                let role = copyStringAttribute(node, kAXRoleAttribute as CFString) ?? ""
                if hasSelectedTextRange(node) && (textLeafRoles.contains(role) || role != rootRole) {
                    return .leaf(node)
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

            // Falling back to children is where an unbounded walk would blow
            // up, so spend a probe per child to find the focused one(s) and
            // follow only those; fanning out across every child is the last
            // resort, and even then only up to `maxChildrenPerNode`.
            let candidates = Array(children(of: node).prefix(maxChildrenPerNode))
            guard !candidates.isEmpty else { continue }
            var focusedChildren: [AXUIElement] = []
            for child in candidates {
                guard budget > 0, CACurrentMediaTime() < deadline else { break }
                budget -= 1
                if isFocused(child) { focusedChildren.append(child) }
            }
            for child in focusedChildren.isEmpty ? candidates : focusedChildren {
                queue.append((child, depth + 1))
            }
        }
        return .none
    }

    // MARK: - Chromium / Electron AX opt-in

    /// Starts nudging Chromium- and Electron-based apps into building their
    /// accessibility tree when they are activated, which is long before the
    /// dictation key is pressed. Call once at launch.
    ///
    /// Doing this on activation rather than inside `current()` is the whole
    /// point: the tree is built while the user is still reaching for the
    /// hotkey, and no part of it lands between the key press and
    /// `AudioRecorder.start()`.
    @MainActor
    static func startObservingAppSwitches() {
        guard !isObservingAppSwitches else { return }
        isObservingAppSwitches = true

        // Whatever is already frontmost never sends an activation
        // notification, so it would otherwise stay un-nudged until the user
        // switched away and back.
        if let front = NSWorkspace.shared.frontmostApplication {
            let pid = front.processIdentifier
            let launchDate = front.launchDate
            let bundleURL = front.bundleURL
            nudgeQueue.async {
                _ = nudge(
                    pid: pid, launchDate: launchDate, bundleURL: bundleURL,
                    requireChromiumLikeBundle: true)
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else { return }
            // Read everything needed off the notification here and hand the
            // background queue value types only.
            let pid = app.processIdentifier
            let launchDate = app.launchDate
            let bundleURL = app.bundleURL
            nudgeQueue.async {
                _ = nudge(
                    pid: pid, launchDate: launchDate, bundleURL: bundleURL,
                    requireChromiumLikeBundle: true)
            }
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else { return }
            forgetNudge(pid: app.processIdentifier)
        }
    }

    static func forgetNudge(pid: pid_t) {
        nudgedAppsLock.lock()
        nudgedApps.removeValue(forKey: pid)
        nudgedAppsLock.unlock()
    }

    /// Sets the two attributes that make a Chromium- or Electron-based app
    /// build out its accessibility tree, at most once per process.
    ///
    /// `AXEnhancedUserInterface` is the flag VoiceOver sets, and it is not
    /// free: on native AppKit apps it changes window-resize and animation
    /// behavior (the thing window managers fight with), and it is never
    /// unset. So it is applied only to apps that look Chromium/Electron
    /// (the activation path) or that have already failed to answer
    /// `kAXFocusedUIElementAttribute` at all, which is the signal that no
    /// tree exists to query (the `current()` path).
    /// `AXManualAccessibility` is Electron-specific and inert elsewhere.
    ///
    /// Returns true when this call is what performed the nudge.
    @discardableResult
    private static func nudge(
        pid: pid_t,
        launchDate: Date?,
        bundleURL: URL? = nil,
        requireChromiumLikeBundle: Bool
    ) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if requireChromiumLikeBundle, !looksChromiumOrElectron(bundleURL: bundleURL) {
            return false
        }

        let stamp = launchDate ?? .distantPast
        nudgedAppsLock.lock()
        let alreadyNudged = nudgedApps[pid] == stamp
        if !alreadyNudged { nudgedApps[pid] = stamp }
        nudgedAppsLock.unlock()
        guard !alreadyNudged else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return true
    }

    /// Chromium and Electron both ship their engine as a framework whose name
    /// ends in " Framework.framework" ("Google Chrome Framework.framework",
    /// "Electron Framework.framework", "Microsoft Edge Framework.framework"),
    /// alongside the renderer helper apps. Ordinary AppKit apps do not, which
    /// is what keeps `AXEnhancedUserInterface` away from them.
    static func looksChromiumOrElectron(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)
        else { return false }
        return names.contains { name in
            name.hasSuffix(" Framework.framework") || name.hasSuffix("Helper (Renderer).app")
        }
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
        //
        // The raw width matters: a genuinely collapsed caret is ~0 wide, so
        // both edges agree. A wide rect means the app answered with the whole
        // line or field instead, and then the trailing edge is the right-hand
        // end of the box rather than where the caret sits.
        Diagnostics.log("caret raw textMarker=\(Diagnostics.describe(cgRect))")
        return caretAnchor(for: cgRect)
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
        Diagnostics.log("caret raw selectedRange=\(Diagnostics.describe(rect))")
        return caretAnchor(for: rect)
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
        guard let rect = caretRect(fromElementOrigin: origin, size: size) else { return nil }
        // An element can report a perfectly well-formed frame that is
        // nowhere any display can show it — scrolled out of a clipping view,
        // or in a window on a display that has since been disconnected.
        // Positioning the panel from that rect makes `PanelPositioner` clamp
        // it to an arbitrary screen edge; returning nil instead gets the
        // predictable bottom-center fallback. The synthesized sliver is
        // checked rather than the raw frame because the sliver is what
        // actually places the panel.
        guard isOnScreen(quartzRect: rect) else { return nil }
        return rect
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

    private static func isOnScreen(quartzRect: CGRect) -> Bool {
        isOnScreen(
            quartzRect: quartzRect,
            screenFramesCocoa: NSScreen.screens.map(\.frame),
            primaryScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    /// Pure geometry, testable without a display: AX reports top-left origins
    /// and `NSScreen` uses bottom-left, the same flip `DictationPanel` does
    /// when picking which screen a caret is on.
    static func isOnScreen(
        quartzRect: CGRect, screenFramesCocoa: [CGRect], primaryScreenMaxY: CGFloat
    ) -> Bool {
        guard !screenFramesCocoa.isEmpty else { return false }
        let cocoaRect = CGRect(
            x: quartzRect.minX,
            y: primaryScreenMaxY - quartzRect.maxY,
            width: quartzRect.width,
            height: quartzRect.height)
        return screenFramesCocoa.contains { $0.intersects(cocoaRect) }
    }

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
