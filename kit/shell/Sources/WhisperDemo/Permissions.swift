import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices

// Preflight TCC (redesign §2 adversarial-pass mitigation): check Mic, Accessibility,
// Input Monitoring at boot; drive a menubar badge — NEVER a window/dialog. One-click
// "open the right Settings pane" surfaced through the menu.
enum Permissions {
    struct Status {
        var mic: Bool
        var accessibility: Bool
        var inputMonitoring: Bool
        var allGranted: Bool { mic && accessibility && inputMonitoring }
    }

    static func check() -> Status {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        // Input Monitoring: preflight without prompting.
        let im = CGPreflightListenEventAccess()
        return Status(mic: mic, accessibility: ax, inputMonitoring: im)
    }

    /// Request mic access (non-blocking); AX/IM cannot be requested programmatically
    /// without a prompt beyond a one-time system dialog — we open the pane instead.
    static func requestMic(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Ask the system for Input Monitoring (shows the one-time prompt the first time).
    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    /// Trigger the Accessibility prompt so WhisperShell appears in the list + a
    /// one-click "Open System Settings" dialog (mirrors how Mic/Input Monitoring prompt).
    static func requestAccessibilityPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openMicPane() { open("Privacy_Microphone") }
    static func openAccessibilityPane() { open("Privacy_Accessibility") }
    static func openInputMonitoringPane() { open("Privacy_ListenEvent") }

    private static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
