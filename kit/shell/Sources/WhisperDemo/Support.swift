import Foundation
import AppKit

// MARK: - Paths (mirror execution/whisperdemo/paths.py)

enum Paths {
    static var stateDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("WhisperDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var configPath: URL { stateDir.appendingPathComponent("config.json") }
    static func log(_ name: String) -> URL { stateDir.appendingPathComponent("\(name).log") }
}

// MARK: - Logging (rotated, stderr + shell.log)

final class Log {
    static let shared = Log()
    private let url = Paths.log("shell")
    private let q = DispatchQueue(label: "wd.log")
    private let maxBytes = 2_000_000

    private init() { rotateIfNeeded() }

    func write(_ msg: String) {
        let line = "[\(Self.ts())] \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        q.async {
            if let h = try? FileHandle(forWritingTo: self.url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8) ?? Data()); try? h.close()
            } else {
                try? line.data(using: .utf8)?.write(to: self.url)
            }
        }
    }

    private func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > maxBytes {
            let one = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.moveItem(at: url, to: one)
        }
    }

    static func ts() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
    }
}

func logmsg(_ s: String) { Log.shared.write(s) }

// MARK: - Config (mirror config.json)

struct Config {
    var engine: String = "pywhispercpp"
    var cleanupMode: String = "regex"
    var hotkeyKeycode: Int = 61            // 61 = Right Option (demo; production owns Left Option 58)
    var tapLatchSeconds: Double = 0.35     // press shorter than this = latch hands-free; longer = push-to-talk
    var prerollSeconds: Double = 0.75
    var streamPreview: Bool = false        // live partial text in the pill while speaking
    var streamIntervalMs: Double = 550     // how often to ask the engine for a partial
    // AI polish pass (the Wisprflow-parity layer). Passed through to the engine
    // verbatim in hello; the shell only reads/writes "mode" for the menu toggle.
    var ai: [String: Any] = [
        "mode": "on",
        "transport": "cli",
        "cli_path": "/opt/homebrew/bin/claude",
        "model": "haiku",
        "timeout_s": 10.0,
        "min_words": 5,
    ]
    // Defaults match where run.sh installs the engine; config.json overrides.
    var pythonPath: String = NSHomeDirectory() + "/Library/Application Support/WhisperDemo/engine-venv/bin/python"
    var engineCwd: String = NSHomeDirectory() + "/Library/Application Support/WhisperDemo/kit"

    var aiOn: Bool { (ai["mode"] as? String ?? "on") == "on" }

    // NOTE: "ai" is deliberately NOT in hello — the engine reads it from config.json
    // at every boot, so the menu toggle (persist + engine restart) always wins over
    // whatever this process captured at launch.
    var helloConfig: [String: Any] {
        ["engine": engine, "cleanup_mode": cleanupMode]
    }

    static func load() -> Config {
        var c = Config()
        if let data = try? Data(contentsOf: Paths.configPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            c.engine = obj["engine"] as? String ?? c.engine
            c.cleanupMode = obj["cleanup_mode"] as? String ?? c.cleanupMode
            c.hotkeyKeycode = obj["hotkey_keycode"] as? Int ?? c.hotkeyKeycode
            c.tapLatchSeconds = obj["tap_latch_seconds"] as? Double ?? c.tapLatchSeconds
            c.prerollSeconds = obj["preroll_seconds"] as? Double ?? c.prerollSeconds
            c.streamPreview = obj["stream_preview"] as? Bool ?? c.streamPreview
            c.streamIntervalMs = obj["stream_interval_ms"] as? Double ?? c.streamIntervalMs
            c.pythonPath = obj["python_path"] as? String ?? c.pythonPath
            c.engineCwd = obj["engine_cwd"] as? String ?? c.engineCwd
            if let a = obj["ai"] as? [String: Any] {
                c.ai = c.ai.merging(a) { _, new in new }
            }
        }
        // Env overrides (installer passes these so the .app is repo-relocatable)
        let env = ProcessInfo.processInfo.environment
        if let p = env["WHISPERDEMO_PYTHON"], !p.isEmpty { c.pythonPath = p }
        if let d = env["WHISPERDEMO_ENGINE_CWD"], !d.isEmpty { c.engineCwd = d }
        if let k = env["WHISPERDEMO_HOTKEY"], let kc = Int(k) { c.hotkeyKeycode = kc }
        return c
    }

    /// Persist the AI mode toggle back to config.json (creates the file if absent).
    static func persistAIMode(_ on: Bool) {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: Paths.configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        var ai = obj["ai"] as? [String: Any] ?? [:]
        ai["mode"] = on ? "on" : "off"
        obj["ai"] = ai
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.configPath)
        }
    }
}

// MARK: - Sounds (distinct from production's Tink/Pop so simultaneous use is unambiguous)

enum Sound {
    static let start = NSSound(contentsOfFile: "/System/Library/Sounds/Ping.aiff", byReference: true)
    static let stop = NSSound(contentsOfFile: "/System/Library/Sounds/Bottle.aiff", byReference: true)
    static func playStart() { start?.stop(); start?.play() }
    static func playStop() { stop?.stop(); stop?.play() }
}
