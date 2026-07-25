import Foundation

// Supervises the python engine child: spawn, pipe protocol, 15s health ping,
// protocol-timeout = kill+restart with exponential backoff. Repeated failures
// raise a menubar badge — never a window/dialog. DEMO variant spawns
// `whisperdemo.engine` (production owns `whisperflow.engine`).
final class EngineSupervisor {
    var onEvent: ((EngineEvent) -> Void)?
    var onHealthy: ((Bool) -> Void)?     // false → badge

    private let pythonPath: String
    private let engineCwd: String
    private let helloConfig: [String: Any]

    private var proc: Process?
    private var stdinPipe: Pipe?
    private let writeQueue = DispatchQueue(label: "wd.engine.write")
    private var stdoutBuffer = Data()

    private var pingTimer: Timer?
    private var pingSeq = 0
    private var lastPong = Date()
    private var ready = false
    private var restartAttempts = 0
    private var intentionalStop = false

    private let engineLog: FileHandle?

    init(pythonPath: String, engineCwd: String, helloConfig: [String: Any]) {
        self.pythonPath = pythonPath
        self.engineCwd = engineCwd
        self.helloConfig = helloConfig
        let logURL = Paths.log("engine")
        // rotate engine.log
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 2_000_000 {
            let one = logURL.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.moveItem(at: logURL, to: one)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        engineLog = try? FileHandle(forWritingTo: logURL)
        engineLog?.seekToEndOfFile()
    }

    func start() {
        intentionalStop = false
        spawn()
    }

    private func spawn() {
        guard !pythonPath.isEmpty, FileManager.default.isExecutableFile(atPath: pythonPath) else {
            logmsg("engine: python not executable at '\(pythonPath)' — check config.json python_path / WHISPERDEMO_PYTHON. Backing off 30s.")
            DispatchQueue.main.async { self.onHealthy?(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if self?.intentionalStop == false { self?.spawn() }
            }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = ["-m", "whisperdemo.engine"]
        p.currentDirectoryURL = URL(fileURLWithPath: engineCwd)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        self.stdinPipe = inPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            self?.ingestStdout(d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            self?.engineLog?.write(d)
        }
        p.terminationHandler = { [weak self] proc in
            self?.handleTermination(code: proc.terminationStatus)
        }

        do {
            try p.run()
            self.proc = p
            logmsg("engine: spawned pid \(p.processIdentifier) (attempt \(restartAttempts))")
            ready = false
            lastPong = Date()
            send(Cmd.hello(config: helloConfig))
            startPingLoop()
        } catch {
            logmsg("engine: spawn failed \(error)")
            scheduleRestart()
        }
    }

    private func ingestStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            guard let ev = EngineEvent.decode(line) else {
                logmsg("engine: non-protocol stdout line ignored: \(line.prefix(80))")
                continue
            }
            handle(ev)
        }
    }

    private func handle(_ ev: EngineEvent) {
        switch ev.type {
        case "ready":
            ready = true
            restartAttempts = 0
            lastPong = Date()
            DispatchQueue.main.async { self.onHealthy?(true) }
        case "health":
            lastPong = Date()
        default:
            break
        }
        DispatchQueue.main.async { self.onEvent?(ev) }
    }

    func send(_ cmd: [String: Any]) {
        guard let data = encodeLine(cmd) else { return }
        writeQueue.async { [weak self] in
            guard let h = self?.stdinPipe?.fileHandleForWriting else { return }
            do { try h.write(contentsOf: data) } catch { logmsg("engine: stdin write failed \(error)") }
        }
    }

    // MARK: health
    private func startPingLoop() {
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            self.pingTimer = t
        }
    }

    private func tick() {
        // protocol-timeout: no pong in >32s (2 missed ticks) while we expected one
        if ready && Date().timeIntervalSince(lastPong) > 32 {
            logmsg("engine: ping timeout — restarting child")
            DispatchQueue.main.async { self.onHealthy?(false) }
            killChild()
            return   // terminationHandler → scheduleRestart
        }
        pingSeq += 1
        send(Cmd.ping(seq: pingSeq))
    }

    private func killChild() {
        proc?.terminate()
        // hard kill fallback
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            if let p = self?.proc, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    private func handleTermination(code: Int32) {
        logmsg("engine: child exited code \(code)")
        pingTimer?.invalidate()
        proc?.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        if intentionalStop { return }
        DispatchQueue.main.async { self.onHealthy?(false) }
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartAttempts += 1
        let delay = min(pow(2.0, Double(restartAttempts)), 30.0)
        logmsg("engine: restart in \(delay)s (attempt \(restartAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.intentionalStop else { return }
            self.stdoutBuffer.removeAll()
            self.spawn()
        }
    }

    func restartNow() {
        logmsg("engine: manual restart requested")
        killChild()
    }

    func stop() {
        intentionalStop = true
        pingTimer?.invalidate()
        send(Cmd.shutdown())
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.killChild() }
    }
}
