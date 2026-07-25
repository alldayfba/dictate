import AppKit
import CoreGraphics

// Paste pipeline (redesign §2, F23): write to clipboard, confirm propagation,
// then synthesize Cmd+V via CGEventPost (primary). osascript is the fallback.
// The transcript is intentionally LEFT on the clipboard as a manual-paste safety net.
enum Paste {
    private static let vKeyCode: CGKeyCode = 9 // ANSI 'v'

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Confirm the pasteboard reflects our text before firing Cmd+V.
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            if pb.string(forType: .string) == text { break }
            usleep(5_000)
        }

        if !postCmdV() {
            logmsg("paste: CGEventPost failed, falling back to osascript")
            osascriptPaste()
        }
    }

    @discardableResult
    private static func postCmdV() -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        let loc: CGEventTapLocation = .cghidEventTap
        down.post(tap: loc)
        up.post(tap: loc)
        return true
    }

    private static func osascriptPaste() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"]
        do { try task.run() } catch { logmsg("osascript paste failed: \(error)") }
    }
}
