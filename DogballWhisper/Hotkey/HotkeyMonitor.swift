import CoreGraphics
import Foundation

enum HotkeyMonitorError: LocalizedError {
    case tapCreationFailed

    var errorDescription: String? {
        "Dogball Whisper could not watch the keyboard. Grant Input Monitoring in System Settings."
    }
}

/// Wraps a CGEventTap and feeds it into HotkeyMatcher. Deliberately thin:
/// all decisions live in the matcher, which is testable.
final class HotkeyMonitor {
    var binding: HotkeyBinding {
        didSet { matcher.binding = binding }
    }

    /// Called when escape is pressed, so the coordinator can abandon work that
    /// is already in flight. Never consumes the key.
    var onEscape: (() -> Void)?

    private static let escapeKeyCode: UInt16 = 53

    private var matcher: HotkeyMatcher
    private let onSignal: (HotkeySignal) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(binding: HotkeyBinding, onSignal: @escaping (HotkeySignal) -> Void) {
        self.binding = binding
        self.matcher = HotkeyMatcher(binding: binding)
        self.onSignal = onSignal
    }

    func start() throws {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyMonitorError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    private func handle(
        proxy: CGEventTapProxy, type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let input: HotkeyInput
        switch type {
        case .flagsChanged: input = .flagsChanged(keyCode: keyCode, flags: event.flags)
        case .keyDown: input = .keyDown(keyCode: keyCode, flags: event.flags)
        default: return Unmanaged.passUnretained(event)
        }

        if type == .keyDown, keyCode == Self.escapeKeyCode, let onEscape {
            DispatchQueue.main.async { onEscape() }
        }

        let consume = matcher.consumesEvent(input)
        if let signal = matcher.handle(input) {
            let callback = onSignal
            DispatchQueue.main.async { callback(signal) }
        }
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
