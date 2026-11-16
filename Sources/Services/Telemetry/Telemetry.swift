import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "telemetry")

enum Telemetry {

    /// Gate every event through this rate (0...1]. Debug builds default to 1.0.
    static var samplingRate: Double = 1.0

    private static let lock = NSLock()
    private static let fileName = "telemetry-events.jsonl"
    private static let maxBytes: Int = 512 * 1024

    /// Record one event. `name` should already follow the naming rules above;
    /// the helpers `success`/`failed` are preferred for paired conversions.
    static func event(_ name: String, _ params: [String: String] = [:]) {
        guard samplingRate >= 1.0 || Double.random(in: 0..<1) < samplingRate else { return }
        let line = Self.Line(name: name, params: params)
        guard let data = try? JSONEncoder().encode(line),
              let text = String(data: data, encoding: .utf8) else { return }
        log.info("\(name, privacy: .public) \(params.description, privacy: .public)")
        lock.lock()
        defer { lock.unlock() }
        append(text)
    }

    /// `"<name>_success"` — one half of a paired conversion.
    static func success(_ name: String, _ params: [String: String] = [:]) {
        event("\(name)_success", params)
    }

    /// `"<name>_failed"` with the failure reason (short, no PII).
    static func failed(_ name: String, reason: String, _ params: [String: String] = [:]) {
        var p = params
        p["reason"] = String(reason.prefix(160))
        event("\(name)_failed", p)
    }

    /// Plaud-style colon escape for screen paths (`device_detail:findmy:click`
    /// → `device_detail_colon_findmy_colon_click`).
    static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: ":", with: "_colon_")
    }

    // MARK: - Disk

    private static var fileURL: URL {
        StorageLocations.root.appendingPathComponent(fileName)
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: StorageLocations.root, withIntermediateDirectories: true)
        if let data = line.appending("\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        rotateIfNeeded()
    }

    /// Half-drop rotation: over budget → keep only the newest half of the lines.
    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        guard let all = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = all.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 4 else { return }
        let keep = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? keep.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    private struct Line: Codable {
        let name: String
        let params: [String: String]
        let at: Date

        init(name: String, params: [String: String]) {
            self.name = name
            self.params = params
            self.at = Date()
        }
    }
}
