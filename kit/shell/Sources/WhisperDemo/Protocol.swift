import Foundation

// Wire protocol — MUST stay in lockstep with execution/whisperdemo/engine.py.
// Newline-delimited JSON, both directions.

// MARK: shell -> engine (commands)

enum Cmd {
    static func hello(config: [String: Any]) -> [String: Any] { ["t": "hello", "config": config] }
    static func start(id: Int) -> [String: Any] { ["t": "start", "id": id] }
    static func audio(id: Int, pcmBase64: String) -> [String: Any] { ["t": "audio", "id": id, "pcm": pcmBase64] }
    static func flush(id: Int) -> [String: Any] { ["t": "flush", "id": id] }
    static func stop(id: Int, duration: Double, appName: String?, bundleID: String?) -> [String: Any] {
        var m: [String: Any] = ["t": "stop", "id": id, "duration": duration]
        if let a = appName { m["app_name"] = a }
        if let b = bundleID { m["bundle_id"] = b }
        return m
    }
    static func cancel(id: Int) -> [String: Any] { ["t": "cancel", "id": id] }
    static func ping(seq: Int) -> [String: Any] { ["t": "ping", "seq": seq] }
    static func statsReq() -> [String: Any] { ["t": "stats_req"] }
    static func shutdown() -> [String: Any] { ["t": "shutdown"] }
}

// MARK: engine -> shell (events) — decoded loosely from a JSON object

struct EngineEvent {
    let type: String
    let raw: [String: Any]

    var id: Int? { raw["id"] as? Int }
    var seq: Int? { raw["seq"] as? Int }
    var text: String? { raw["text"] as? String }
    var rawText: String? { raw["raw"] as? String }
    var paste: Bool { (raw["paste"] as? Bool) ?? true }
    var msg: String? { raw["msg"] as? String }
    var level: String { (raw["level"] as? String) ?? "info" }
    var engine: String? { raw["engine"] as? String }
    var model: String? { raw["model"] as? String }
    var state: String? { raw["state"] as? String }
    var total: Int { (raw["total"] as? Int) ?? 0 }
    var today: Int { (raw["today"] as? Int) ?? 0 }
    var chars: Int { (raw["chars"] as? Int) ?? 0 }

    static func decode(_ line: String) -> EngineEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String else { return nil }
        return EngineEvent(type: t, raw: obj)
    }
}

func encodeLine(_ obj: [String: Any]) -> Data? {
    guard var data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return nil }
    data.append(0x0A) // newline
    return data
}
