import Foundation

enum ClipOrigin {

    static let watch = "watch"
    static let phone = "phone"

    private static func url(forClipName name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        return StorageLocations.decryptedDir.appendingPathComponent("\(base).origin")
    }

    static func mark(_ origin: String, forClipName name: String) {
        let target = url(forClipName: name)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data(origin.utf8).write(to: target, options: .atomic)
    }

    static func of(_ clipName: String) -> String? {
        guard let data = try? Data(contentsOf: url(forClipName: clipName)),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Only recordings explicitly marked as watch recordings qualify.
    static func isWatch(_ clipName: String) -> Bool {
        of(clipName) == watch
    }

    static func remove(forClipName name: String) {
        try? FileManager.default.removeItem(at: url(forClipName: name))
    }
}
