import AppKit

// Floating pill overlay — DEMO variant: deep red pill (vs production's black) sitting
// 50pt higher so both apps can run simultaneously without overlapping. Dark rounded
// pill with 15 animated dots (recording), a progress bar (transcribing/polishing),
// and a transient notification toast. Repositions on screen-param changes.

enum OverlayState { case recording, paused, transcribing }

final class WaveformView: NSView {
    static let numDots = 15
    static let dotRadius: CGFloat = 2.5
    static let dotGap: CGFloat = 5
    static let paddingH: CGFloat = 16
    static let pillHeight: CGFloat = 36

    var state: OverlayState = .recording
    var dotLevels = [CGFloat](repeating: 0, count: WaveformView.numDots)
    var progress: CGFloat = 0
    var notificationText: String = ""
    var notificationUntil: Date = .distantPast
    var partialText: String = ""     // live-preview transcription while recording
    var stageLabel: String = ""      // "" = default Thinking/Transcribing; engine can set "Polishing…"

    static var pillWidth: CGFloat {
        let dotsW = CGFloat(numDots) * (dotRadius * 2 + dotGap) - dotGap
        return paddingH + dotsW + paddingH
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        let radius = h / 2

        // DEMO identity: deep "REC" red (production pill is near-black).
        NSColor(calibratedRed: 0.55, green: 0.10, blue: 0.12, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: radius, yRadius: radius).fill()

        // Notification toast overrides everything while active.
        if !notificationText.isEmpty && Date() < notificationUntil {
            let fade = max(0, min(1, CGFloat(notificationUntil.timeIntervalSinceNow) / 0.5))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.7, alpha: fade),
            ]
            let s = NSAttributedString(string: notificationText, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: (w - sz.width) / 2, y: (h - sz.height) / 2))
            return
        }

        if state == .transcribing {
            let barH: CGFloat = 4
            let barMargin = Self.paddingH + 4
            let barW = w - barMargin * 2
            let barY: CGFloat = 8
            NSColor(calibratedRed: 0.35, green: 0.15, blue: 0.16, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: barMargin, y: barY, width: barW, height: barH), xRadius: 2, yRadius: 2).fill()
            NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.40, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: barMargin, y: barY, width: barW * progress, height: barH), xRadius: 2, yRadius: 2).fill()
            let label = stageLabel.isEmpty ? (progress < 0.3 ? "Thinking..." : "Transcribing...") : stageLabel
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedRed: 0.95, green: 0.80, blue: 0.78, alpha: 1),
            ]
            let s = NSAttributedString(string: label, attributes: attrs)
            s.draw(at: NSPoint(x: (w - s.size().width) / 2, y: barY + barH + 5))
            return
        }

        // Live preview: show the running transcription (tail) instead of dots.
        if state == .recording && !partialText.isEmpty {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingHead   // keep the newest words visible
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
                .paragraphStyle: para,
            ]
            let inset: CGFloat = 16
            let r = NSRect(x: inset, y: (h - 18) / 2, width: w - inset * 2, height: 18)
            (partialText as NSString).draw(in: r, withAttributes: attrs)
            return
        }

        // Recording / paused: animated dots.
        let dotsTotalW = CGFloat(Self.numDots) * (Self.dotRadius * 2 + Self.dotGap) - Self.dotGap
        let startX = (w - dotsTotalW) / 2
        let cy = h / 2
        for i in 0..<Self.numDots {
            let val = dotLevels[i]
            let dotH = Self.dotRadius * 2 + val * 24
            let dotW = Self.dotRadius * 2
            let dx = startX + CGFloat(i) * (Self.dotRadius * 2 + Self.dotGap)
            let dy = cy - dotH / 2
            if state == .paused {
                NSColor(calibratedRed: 0.78, green: 0.48, blue: 0.48, alpha: 0.7).setFill()
            } else {
                let b = 0.6 + val * 0.4
                NSColor(calibratedRed: b, green: b, blue: b, alpha: 1).setFill()
            }
            NSBezierPath(roundedRect: NSRect(x: dx, y: dy, width: dotW, height: dotH), xRadius: Self.dotRadius, yRadius: Self.dotRadius).fill()
        }
    }
}

final class Overlay {
    private var panel: NSPanel!
    private var view: WaveformView!
    private var timer: Timer?
    private var amplitude: CGFloat = 0
    private var startTime = Date()

    init() { buildPanel(); observeScreenChanges() }

    private func buildPanel() {
        let w = WaveformView.pillWidth
        let h = WaveformView.pillHeight
        let frame = originFrame(w: w, h: h)
        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: 101)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.alphaValue = 0.95
        p.hasShadow = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        let v = WaveformView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        p.contentView = v
        self.panel = p
        self.view = v
    }

    private func originFrame(w: CGFloat, h: CGFloat) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let sf = screen.frame
        let x = sf.origin.x + (sf.width - w) / 2
        let y = sf.origin.y + 190   // production sits at 140 — demo rides 50pt above it
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.panel.setFrame(self.originFrame(w: WaveformView.pillWidth, h: WaveformView.pillHeight), display: true)
        }
    }

    func setState(_ s: OverlayState) {
        DispatchQueue.main.async {
            self.view.state = s
            if s != .recording { self.view.partialText = "" }   // clear preview when leaving record
            if s != .transcribing { self.view.stageLabel = "" }
        }
    }

    func setStage(_ label: String) {
        DispatchQueue.main.async {
            self.view.stageLabel = label
            self.view.needsDisplay = true
        }
    }

    /// Live-preview partial: show the running text and grow the pill to fit (capped).
    func showPartial(_ text: String) {
        DispatchQueue.main.async {
            guard self.view.state == .recording else { return }
            self.view.partialText = text
            let font = NSFont.systemFont(ofSize: 13, weight: .medium)
            let measured = (text as NSString).size(withAttributes: [.font: font]).width
            let w = max(WaveformView.pillWidth, min(640, measured + 48))
            self.resize(toWidth: w)
            self.view.needsDisplay = true
        }
    }

    private func resize(toWidth w: CGFloat) {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let sf = screen.frame
        let h = WaveformView.pillHeight
        let x = sf.origin.x + (sf.width - w) / 2
        let y = panel.frame.origin.y
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        view.frame = NSRect(x: 0, y: 0, width: w, height: h)
    }
    func updateAmplitude(_ a: Double) { DispatchQueue.main.async { self.amplitude = CGFloat(a) } }
    func updateProgress(_ p: Double) { DispatchQueue.main.async { self.view.progress = CGFloat(max(0, min(1, p))) } }

    func showNotification(_ text: String, duration: TimeInterval = 3.0) {
        DispatchQueue.main.async {
            self.view.notificationText = text
            self.view.notificationUntil = Date().addingTimeInterval(duration)
            if self.panel.isVisible == false { self.show(state: .transcribing) }
            self.view.needsDisplay = true
        }
    }

    func show(state: OverlayState) {
        DispatchQueue.main.async {
            self.view.state = state
            self.view.partialText = ""
            self.view.stageLabel = ""
            self.view.frame = NSRect(x: 0, y: 0, width: WaveformView.pillWidth, height: WaveformView.pillHeight)
            for i in 0..<self.view.dotLevels.count { self.view.dotLevels[i] = 0 }
            self.amplitude = 0
            self.startTime = Date()
            self.panel.setFrame(self.originFrame(w: WaveformView.pillWidth, h: WaveformView.pillHeight), display: false)
            self.panel.orderFront(nil)
            self.timer?.invalidate()
            let t = Timer(timeInterval: 0.033, repeats: true) { [weak self] _ in self?.animate() }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.timer?.invalidate(); self.timer = nil
            // Keep pill up briefly if a notification is still showing.
            if !self.view.notificationText.isEmpty && Date() < self.view.notificationUntil {
                let rem = self.view.notificationUntil.timeIntervalSinceNow
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, rem)) { self.panel.orderOut(nil) }
            } else {
                self.panel.orderOut(nil)
            }
        }
    }

    private func animate() {
        let t = Date().timeIntervalSince1970
        let n = view.dotLevels.count
        switch view.state {
        case .paused:
            for i in 0..<n { view.dotLevels[i] *= 0.9 }
        case .transcribing:
            for i in 0..<n {
                let phase = (t * 3.0 - Double(i) * 0.3).truncatingRemainder(dividingBy: .pi * 2)
                view.dotLevels[i] = CGFloat(max(0.08, abs(sin(phase)) * 0.6))
            }
        case .recording:
            let amp = Double(amplitude)
            for i in 0..<n {
                let wave1 = sin(t * 6.0 + Double(i) * 0.7) * 0.25
                let wave2 = sin(t * 10.0 + Double(i) * 1.3) * 0.2
                let jitter = sin(t * 15.0 + Double(i) * 2.1) * 0.1
                let centerW = 1.0 - abs(Double(i) - Double(n) / 2) / (Double(n) / 2) * 0.25
                let target = max(0.01, min(1.0, amp * centerW * (0.3 + wave1 + wave2 + jitter)))
                let cur = Double(view.dotLevels[i])
                let next = target > cur ? cur + (target - cur) * 0.6 : cur + (target - cur) * 0.2
                view.dotLevels[i] = CGFloat(next)
            }
        }
        view.needsDisplay = true
    }
}
