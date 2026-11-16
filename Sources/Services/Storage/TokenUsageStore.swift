import Combine
import Foundation

final class TokenUsageStore: ObservableObject {

    static let shared = TokenUsageStore()

    /// `yyyy-MM-dd` → 估算 token 数。
    @Published private(set) var daily: [String: Int] = [:]
    /// 当天调用次数（用于「这天没有用大模型」之外的明细）。
    @Published private(set) var callsByDay: [String: Int] = [:]

    private let queue = DispatchQueue(label: "com.nomily.app.tokenusage", qos: .utility)

    private init() { load() }

    /// 记一次完成：输入 + 输出字符数 → 估算 token。
    func record(inputChars: Int, outputChars: Int) {
        let tokens = Int(Double(max(0, inputChars + outputChars)) * 0.62)
        guard tokens > 0 else { return }
        let key = Self.dayKey(Date())
        daily[key, default: 0] += tokens
        callsByDay[key, default: 0] += 1
        persist()
    }

    /// 热力图用：最近 `days` 天（含今天）的 (日期, token) 序列，缺天补 0。
    func recent(days: Int) -> [(date: Date, tokens: Int, calls: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = Self.dayKey(date)
            return (date, daily[key] ?? 0, callsByDay[key] ?? 0)
        }
    }

    static func dayKey(_ date: Date) -> String {
        keyFormatter.string(from: date)
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - persistence

    private struct Snapshot: Codable {
        var daily: [String: Int]
        var calls: [String: Int]
    }

    private var url: URL {
        StorageLocations.root.appendingPathComponent("token-usage.json", isDirectory: false)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        daily = snap.daily
        callsByDay = snap.calls
    }

    private func persist() {
        let snap = Snapshot(daily: daily, calls: callsByDay)
        let target = url
        queue.async {
            guard let data = try? JSONEncoder().encode(snap) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }
}
