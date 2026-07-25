import AppKit
import CoreGraphics

// CGEventTap hotkey — DEMO variant with Wisprflow-style push-to-talk semantics:
//   • press & hold  → record while held; release (≥ tapLatch) stops + transcribes
//   • quick tap (< tapLatch) → latch hands-free; next tap stops + transcribes
//   • Esc while recording → cancel (nothing pastes)
//   • tap while transcribing → clear a stuck overlay
// The tap is passive (.listenOnly) — never swallows the user's keys, so Esc also
// reaches the frontmost app (documented demo trade-off). Re-enables itself when
// macOS disables the tap.
final class Hotkey {
    var onStart: (() -> Void)?          // key down while idle → begin recording
    var onStop: (() -> Void)?           // stop + transcribe
    var onCancel: (() -> Void)?         // abort recording, nothing pastes
    var onStuckClear: (() -> Void)?     // tap while transcribing
    var isActive: (() -> Bool)?         // true while recording (held or latched)
    var isTranscribing: (() -> Bool)?

    private let targetKeycode: Int
    private let tapLatch: Double
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private var keyIsDown = false
    private var downTime: CFTimeInterval = 0
    private var startedThisPress = false   // this press began the recording (PTT candidate)
    private var comboKeyPressed = false    // another key fired while our key was down

    private let escKeycode = 53

    init(keycode: Int, tapLatchSeconds: Double) {
        self.targetKeycode = keycode
        self.tapLatch = tapLatchSeconds
    }

    @discardableResult
    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,               // passive — never swallow the user's keys
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyCallback,
            userInfo: refcon
        ) else {
            logmsg("hotkey: CGEvent.tapCreate FAILED (needs Accessibility + Input Monitoring)")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logmsg("hotkey: tap active on keycode \(targetKeycode) (PTT hold, tap-latch \(tapLatch)s)")
        return true
    }

    func reEnable() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true); logmsg("hotkey: re-enabled after system disable") }
    }

    // Called from the C trampoline.
    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard kc == targetKeycode else { return }
            keyIsDown.toggle()
            logmsg("hotkey: option \(keyIsDown ? "down" : "up")")
            if keyIsDown {
                downTime = CACurrentMediaTime()
                comboKeyPressed = false
                if isTranscribing?() == true {
                    startedThisPress = false          // handled on the up (stuck-clear)
                } else if isActive?() != true {
                    startedThisPress = true
                    onStart?()                        // PTT: recording begins on key DOWN
                } else {
                    startedThisPress = false          // latched — this press will stop on the up
                }
            } else {
                if downTime <= 0 { return }
                let held = CACurrentMediaTime() - downTime
                downTime = 0
                if isTranscribing?() == true { onStuckClear?(); return }
                guard isActive?() == true else { return }
                if startedThisPress {
                    if comboKeyPressed && held < tapLatch {
                        onCancel?()                   // Option+key combo — abort the accidental start
                    } else if held >= tapLatch {
                        onStop?()                     // PTT release → transcribe
                    }
                    // else: quick tap → latch hands-free (keep recording)
                } else {
                    onStop?()                         // tap while latched → transcribe
                }
                startedThisPress = false
            }
        case .keyDown:
            let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if kc == escKeycode, isActive?() == true {
                onCancel?()                           // Esc cancels (also reaches the app — listen-only tap)
                return
            }
            comboKeyPressed = true
        default:
            break
        }
    }
}

// C-compatible trampoline: bridges refcon back to the Hotkey instance, handles
// the system-disable events, and always passes the event through unmodified.
private func hotkeyCallback(proxy: CGEventTapProxy,
                            type: CGEventType,
                            event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon = refcon {
            Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue().reEnable()
        }
        return Unmanaged.passUnretained(event)
    }
    if let refcon = refcon {
        Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
