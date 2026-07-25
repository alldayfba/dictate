import AVFoundation
import CoreAudio

// Mic capture moves INTO the shell (redesign §2/§3): AVAudioEngine input tap →
// AVAudioConverter → 16k mono float32. Proper resampling kills the aliasing/44.1k
// decimation bug (audit F7). Always-on ring buffer keeps a 0.75s pre-roll so a tap
// grabs audio from *before* the keypress — no first-word cutoff (best idea in the old code).
final class AudioCapture {
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16000, channels: 1, interleaved: false)!
    private let ringLock = NSLock()
    private var ring: [Float] = []
    private let ringMax: Int
    private var running = false

    // Watchdog: CoreAudio can wedge the input tap with NO configuration-change
    // notification (observed 2026-07-09/10 — hotkeys fire, preroll=0, zero samples
    // forever). The tap is always-on (ring fills even when idle), so "no buffer in
    // N seconds" reliably means dead, not quiet.
    private var lastBufferAt = Date()
    private var watchdogTimer: Timer?
    private var deadRestarts = 0
    private var nextRestartAllowed = Date.distantPast
    private let staleAfter: TimeInterval = 3.0

    var isRecording = false
    var onFrame: (([Float]) -> Void)?
    var onAmplitude: ((Double) -> Void)?
    var onError: ((String) -> Void)?

    init(prerollSeconds: Double = 0.75) {
        ringMax = Int(16000.0 * prerollSeconds)
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
        startWatchdog()
    }

    func start() {
        guard !running else { return }
        do {
            try installTapAndStart()
            running = true
            stampBuffer()   // grace period so the watchdog doesn't fire before first buffer
            logmsg("audio: engine started")
        } catch {
            onError?("audio start failed: \(error.localizedDescription)")
            logmsg("audio: start failed \(error)")
        }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw NSError(domain: "wf", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input format"]) }
        converter = AVAudioConverter(from: inFormat, to: outFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    @objc private func configChanged() {
        // Device switch (EarPods↔internal↔AirPods) or format change — rebuild the tap.
        logmsg("audio: configuration change — restarting tap")
        restart()
    }

    func restart() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        // brief settle so CoreAudio finishes the device swap before we re-open
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.start() }
    }

    // MARK: watchdog

    private func stampBuffer() {
        ringLock.lock(); lastBufferAt = Date(); ringLock.unlock()
    }

    private func startWatchdog() {
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.checkPulse() }
        RunLoop.main.add(t, forMode: .common)
        watchdogTimer = t
    }

    private func checkPulse() {
        guard running else { return }
        ringLock.lock(); let last = lastBufferAt; ringLock.unlock()
        let age = Date().timeIntervalSince(last)
        if age < staleAfter {
            if deadRestarts > 0 {
                logmsg("audio: watchdog — buffers flowing again, recovered after \(deadRestarts) restart(s)")
                deadRestarts = 0
                nextRestartAllowed = .distantPast
            }
            return
        }
        guard Date() >= nextRestartAllowed else { return }
        deadRestarts += 1
        // exponential backoff, capped — keeps retrying forever (mic may come back)
        // without spinning when there's genuinely no input device
        let backoff = min(60.0, pow(2.0, Double(min(deadRestarts, 6))))
        nextRestartAllowed = Date().addingTimeInterval(backoff)
        logmsg(String(format: "audio: watchdog — no mic buffers for %.1fs, restarting tap (attempt %d)", age, deadRestarts))
        if deadRestarts >= 3 {
            rebuildEngine()   // same-engine restarts didn't take — the HAL IO proc is wedged
        } else {
            restart()
        }
    }

    /// Nuclear option: a wedged CoreAudio IO proc can survive stop()/start() on the
    /// same AVAudioEngine. Tear the whole engine down and build a fresh one.
    private func rebuildEngine() {
        logmsg("audio: watchdog — rebuilding AVAudioEngine")
        NotificationCenter.default.removeObserver(
            self, name: .AVAudioEngineConfigurationChange, object: engine)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        engine = AVAudioEngine()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.start() }
    }

    /// Called at recording start: if the tap has gone silent, kick a restart
    /// immediately instead of waiting for the next watchdog tick.
    func ensureAlive() {
        guard running else { start(); return }
        ringLock.lock(); let last = lastBufferAt; ringLock.unlock()
        if Date().timeIntervalSince(last) > staleAfter {
            logmsg("audio: ensureAlive — tap silent at rec start, forcing restart")
            restart()
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        stampBuffer()
        guard let converter = converter else { return }
        let ratio = 16000.0 / buffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return }

        var supplied = false
        var convErr: NSError?
        let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || convErr != nil {
            logmsg("audio: convert error \(String(describing: convErr))")
            return
        }
        let n = Int(outBuf.frameLength)
        guard n > 0, let ch = outBuf.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))

        // Amplitude for the overlay (port of monolith formula).
        var peak: Float = 0, sumsq: Float = 0
        for s in samples { let a = abs(s); if a > peak { peak = a }; sumsq += s * s }
        let rms = (n > 0) ? (sumsq / Float(n)).squareRoot() : 0
        let amp = min(1.0, Double(peak) * 0.6 + Double(rms) * 0.4) * 25.0
        onAmplitude?(min(1.0, amp))

        if isRecording {
            onFrame?(samples)
        } else {
            ringLock.lock()
            ring.append(contentsOf: samples)
            if ring.count > ringMax { ring.removeFirst(ring.count - ringMax) }
            ringLock.unlock()
        }
    }

    /// Snapshot the pre-roll (last ~0.75s) and clear the ring. Call at recording start.
    func snapshotPreroll() -> [Float] {
        ringLock.lock(); defer { ringLock.unlock() }
        let pre = ring
        ring.removeAll(keepingCapacity: true)
        return pre
    }

    /// Idle max-peak backstop (audit "mic dead vs user quiet"): expose recent ring energy.
    func idleMaxPeak() -> Float {
        ringLock.lock(); defer { ringLock.unlock() }
        return ring.reduce(Float(0)) { max($0, abs($1)) }
    }
}

// Encode Float samples as base64 little-endian float32 for the pipe.
func base64F32(_ samples: [Float]) -> String {
    // host is little-endian on Apple Silicon → raw float32-LE bytes, as the engine expects
    let data = samples.withUnsafeBytes { Data($0) }
    return data.base64EncodedString()
}
