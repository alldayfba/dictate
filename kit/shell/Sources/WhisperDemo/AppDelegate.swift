import AppKit

// Faceless menubar app (LSUIElement). DEMO variant: red identity (🟥), AI Polish
// toggle, no Teach/Jarvis/engine-swap. Owns the status item, the menu, and the
// permission preflight badge.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: Controller!
    private var config = Config.load()
    private var degraded = false
    private var recState: RecState = .idle
    private var engineName = "…"
    private var modelName = "…"
    private var stats = (total: 0, today: 0, chars: 0)
    private var aiOn: Bool

    private let icons: [RecState: String] = [
        .idle: "🟥", .recording: "🎙", .transcribing: "⏳",
    ]

    override init() {
        aiOn = config.aiOn
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        enforceSingleInstance()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = icons[.idle]!
        buildMenu()

        controller = Controller(config: config)
        controller.onMenuState = { [weak self] s in self?.updateState(s) }
        controller.onReady = { [weak self] eng, model in
            self?.engineName = eng; self?.modelName = model
            self?.degraded = false; self?.refreshIcon()
            logmsg("shell: engine ready \(eng)/\(model)")
        }
        controller.onStats = { [weak self] t, d, c in self?.stats = (t, d, c) }
        controller.supervisor.onHealthy = { [weak self] ok in
            self?.degraded = !ok; self?.refreshIcon()
        }

        preflightPermissions()
        controller.start()

        // Start the hotkey tap; if TCC not yet granted it fails → badge + menu prompt.
        if !controller.hotkey.start() {
            degraded = true; refreshIcon()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    private func enforceSingleInstance() {
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier:
            Bundle.main.bundleIdentifier ?? "com.dictate.voice")
            .filter { $0.processIdentifier != me.processIdentifier }
        if !others.isEmpty {
            logmsg("shell: another instance running — exiting")
            NSApp.terminate(nil)
        }
    }

    // MARK: permissions
    private func preflightPermissions() {
        let s = Permissions.check()
        logmsg("perms: mic=\(s.mic) ax=\(s.accessibility) im=\(s.inputMonitoring)")
        if !s.mic { Permissions.requestMic { _ in } }
        if !s.inputMonitoring { Permissions.requestInputMonitoring() }
        if !s.accessibility { Permissions.requestAccessibilityPrompt() }
        if !s.allGranted { degraded = true; refreshIcon() }
    }

    // MARK: icon / state
    private func updateState(_ s: RecState) { recState = s; refreshIcon() }
    private func refreshIcon() {
        DispatchQueue.main.async {
            let base = self.icons[self.recState] ?? "🟥"
            self.statusItem.button?.title = self.degraded ? "⚠️" + base : base
        }
    }

    // MARK: menu
    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller?.requestStats()
        menu.removeAllItems()

        let header = NSMenuItem(title: "WhisperDemo — \(stateLabel(recState))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let hint = NSMenuItem(title: "Hold ⌥ (right) to talk · tap to latch · Esc cancels", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let s = Permissions.check()
        if !s.allGranted {
            let warn = NSMenuItem(title: "⚠️ Permissions needed", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            if !s.mic { menu.addItem(item("  Grant Microphone…", #selector(openMic))) }
            if !s.accessibility { menu.addItem(item("  Grant Accessibility…", #selector(openAX))) }
            if !s.inputMonitoring { menu.addItem(item("  Grant Input Monitoring…", #selector(openIM))) }
            menu.addItem(.separator())
        }

        let ai = item("AI Polish (Claude cleanup + tone)", #selector(toggleAI))
        ai.state = aiOn ? .on : .off
        menu.addItem(ai)
        let live = item("Live Preview (words as you speak)", #selector(toggleLive))
        live.state = controller.streamPreview ? .on : .off
        menu.addItem(live)
        let hist = NSMenuItem(title: "History: \(stats.total) total · \(stats.today) today", action: nil, keyEquivalent: "")
        hist.isEnabled = false
        menu.addItem(hist)
        menu.addItem(.separator())

        let health = NSMenuItem(title: "Engine: \(engineName)/\(modelName)\(degraded ? " ⚠️" : " ✓")", action: nil, keyEquivalent: "")
        health.isEnabled = false
        menu.addItem(health)
        menu.addItem(item("Restart Engine", #selector(restartEngine)))

        menu.addItem(.separator())
        menu.addItem(item("Quit WhisperDemo", #selector(quit)))
    }

    private func stateLabel(_ s: RecState) -> String {
        switch s { case .idle: return "idle"; case .recording: return "recording";
                   case .transcribing: return "transcribing" }
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        return mi
    }

    // MARK: actions
    @objc private func openMic() { Permissions.openMicPane() }
    @objc private func openAX() { Permissions.openAccessibilityPane() }
    @objc private func openIM() { Permissions.openInputMonitoringPane() }
    @objc private func restartEngine() { controller.supervisor.restartNow() }
    @objc private func toggleLive() { controller.setStreamPreview(!controller.streamPreview) }
    @objc private func toggleAI() {
        aiOn.toggle()
        Config.persistAIMode(aiOn)
        // Engine reads config.json at boot — restart to apply.
        controller.supervisor.restartNow()
        logmsg("shell: AI Polish -> \(aiOn ? "on" : "off") (engine restarting)")
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
