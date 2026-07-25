import AppKit

// The orchestrator: owns the recording state machine and wires hotkey → audio →
// engine → overlay → paste. Runs on the main thread (hotkey + engine events both
// dispatch here). DEMO variant: PTT semantics, Esc cancel, frontmost-app capture
// for the AI tone layer, and engine "stage" events driving the pill label.
enum RecState { case idle, recording, transcribing }

final class Controller {
    private let config: Config
    private let audio: AudioCapture
    private let overlay = Overlay()
    let hotkey: Hotkey
    let supervisor: EngineSupervisor

    private(set) var state: RecState = .idle
    private var currentId = 0
    private var recordingStart = Date()
    private var flushTimer: Timer?
    private(set) var streamPreview: Bool

    var onMenuState: ((RecState) -> Void)?
    var onReady: ((String, String) -> Void)?          // engine, model
    var onStats: ((Int, Int, Int) -> Void)?           // total, today, chars

    init(config: Config) {
        self.config = config
        self.streamPreview = config.streamPreview
        self.audio = AudioCapture(prerollSeconds: config.prerollSeconds)
        self.hotkey = Hotkey(keycode: config.hotkeyKeycode, tapLatchSeconds: config.tapLatchSeconds)
        self.supervisor = EngineSupervisor(pythonPath: config.pythonPath,
                                           engineCwd: config.engineCwd,
                                           helloConfig: config.helloConfig)
        wire()
    }

    private func wire() {
        audio.onAmplitude = { [weak self] amp in self?.overlay.updateAmplitude(amp) }
        audio.onFrame = { [weak self] samples in
            guard let self = self else { return }
            // only stream while actively recording
            self.supervisor.send(Cmd.audio(id: self.currentId, pcmBase64: base64F32(samples)))
        }
        audio.onError = { msg in logmsg("audio error: \(msg)") }

        hotkey.isActive = { [weak self] in self?.state == .recording }
        hotkey.isTranscribing = { [weak self] in self?.state == .transcribing }
        hotkey.onStart = { [weak self] in self?.startRecording() }
        hotkey.onStop = { [weak self] in self?.stopRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        hotkey.onStuckClear = { [weak self] in
            self?.overlay.hide()
            self?.setState(.idle)
        }

        supervisor.onEvent = { [weak self] ev in self?.onEngineEvent(ev) }
    }

    func start() {
        audio.start()
        supervisor.start()
    }

    func stop() {
        supervisor.stop()
    }

    // MARK: state transitions
    private func startRecording() {
        guard state == .idle else { return }
        audio.ensureAlive()   // dead-tap self-heal: recover mid-recording instead of capturing nothing
        Sound.playStart()
        currentId += 1
        recordingStart = Date()
        overlay.show(state: .recording)
        let preroll = audio.snapshotPreroll()
        audio.isRecording = true
        supervisor.send(Cmd.start(id: currentId))
        if !preroll.isEmpty {
            supervisor.send(Cmd.audio(id: currentId, pcmBase64: base64F32(preroll)))
        }
        setState(.recording)
        startFlushTimer()
        logmsg("rec: start id=\(currentId) preroll=\(preroll.count) samples stream=\(streamPreview)")
    }

    private func stopRecording() {
        guard state == .recording else { return }
        stopFlushTimer()
        audio.isRecording = false
        Sound.playStop()
        let dur = Date().timeIntervalSince(recordingStart)
        // Capture the destination app NOW (before any focus change) — drives the AI tone preset.
        let front = NSWorkspace.shared.frontmostApplication
        overlay.setState(.transcribing)
        overlay.updateProgress(0.35)
        setState(.transcribing)
        supervisor.send(Cmd.stop(id: currentId, duration: dur,
                                 appName: front?.localizedName,
                                 bundleID: front?.bundleIdentifier))
        logmsg("rec: stop id=\(currentId) dur=\(String(format: "%.2f", dur))s app=\(front?.localizedName ?? "?")")
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        stopFlushTimer()
        audio.isRecording = false
        Sound.playStop()
        overlay.hide()
        supervisor.send(Cmd.cancel(id: currentId))
        setState(.idle)
        logmsg("rec: cancel id=\(currentId)")
    }

    // Live preview: periodically ask the engine for a partial transcription.
    private func startFlushTimer() {
        stopFlushTimer()
        guard streamPreview else { return }
        let t = Timer(timeInterval: config.streamIntervalMs / 1000.0, repeats: true) { [weak self] _ in
            guard let self = self, self.state == .recording else { return }
            self.supervisor.send(Cmd.flush(id: self.currentId))
        }
        RunLoop.main.add(t, forMode: .common)
        flushTimer = t
    }

    private func stopFlushTimer() { flushTimer?.invalidate(); flushTimer = nil }

    func setStreamPreview(_ on: Bool) {
        streamPreview = on
        if !on { stopFlushTimer() } else if state == .recording { startFlushTimer() }
    }

    private func setState(_ s: RecState) {
        state = s
        onMenuState?(s)
    }

    // MARK: engine events
    private func onEngineEvent(_ ev: EngineEvent) {
        switch ev.type {
        case "ready":
            onReady?(ev.engine ?? "?", ev.model ?? "?")
        case "partial":
            if state == .recording { overlay.showPartial(ev.text ?? "") }
        case "stage":
            if state == .transcribing {
                overlay.setStage(ev.text ?? "")
                overlay.updateProgress(0.7)
            }
        case "final":
            overlay.updateProgress(1.0)
            overlay.hide()
            if state == .transcribing { setState(.idle) }
            let text = ev.text ?? ""
            if ev.paste && !text.isEmpty {
                Paste.paste(text)
            }
        case "notify":
            overlay.showNotification(ev.text ?? "", duration: 2.5)
        case "stats":
            onStats?(ev.total, ev.today, ev.chars)
        case "error":
            logmsg("engine error: \(ev.msg ?? "?")")
            if state == .transcribing { overlay.hide(); setState(.idle) }
        default:
            break
        }
    }

    func requestStats() { supervisor.send(Cmd.statsReq()) }
}
