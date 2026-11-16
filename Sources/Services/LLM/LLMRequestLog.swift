import Foundation
import os

enum LLMRequestLog {

    private static let log = Logger(subsystem: "com.nomily.app", category: "LLM-Request")
    private static let queue = DispatchQueue(label: "com.nomily.app.llm-request-log")
    private static let maxBytes = 64 * 1024

    /// Logs the *intent* before any URL is built — so an address that can't even
    /// become a `URL` (missing scheme, stray character pasted from the console)
    /// still leaves a trace, instead of failing silently with no file at all.
    static func attempt(provider: String, endpoint: String, protocol wire: LLMWireProtocol, hasKey: Bool) {
        let raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "\(stamp()) ATTEMPT \(provider) proto=\(wire.rawValue) "
            + "endpoint=\(raw.isEmpty ? "(empty)" : raw) key=\(hasKey ? "yes" : "no")"
        log.notice("\(line, privacy: .public)")
        queue.async { append(line) }
    }

    static func record(_ req: URLRequest, code: Int, millis: Int, note: String = "") {        let method = req.httpMethod ?? "GET"
        let url = req.url
        let host = url?.host() ?? "?"
        let path = url?.path ?? "?"
        let hasKey = !(req.value(forHTTPHeaderField: "Authorization") ?? "").isEmpty
            || !(req.value(forHTTPHeaderField: "x-api-key") ?? "").isEmpty
        let line = "\(stamp()) \(method) \(host)\(path) -> \(code) \(millis)ms key=\(hasKey ? "yes" : "no") \(note)"
        log.notice("\(line, privacy: .public)")
        queue.async { append(line) }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func append(_ line: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let url = dir.appendingPathComponent("llm-requests.log")
        let fm = FileManager.default
        // Rotate instead of growing forever: 64 KB is hundreds of attempts.
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxBytes {
            try? fm.removeItem(at: url)
        }
        let text = line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
