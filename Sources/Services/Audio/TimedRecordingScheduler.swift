import Foundation
import os.log
import UserNotifications

private let log = Logger(subsystem: "com.nomily.app.ios", category: "timed-rec")

@MainActor
final class TimedRecordingScheduler: ObservableObject {

    static let shared = TimedRecordingScheduler()
    private init() {}

    @Published private(set) var isTimedRecording = false
    /// Last status line for the settings page (start/stop/missed notices).
    @Published var lastNotice: String?

    private var heartbeat: Timer?
    private weak var configService: ConfigService?
    private weak var watch: WatchSyncService?

    /// 已发出 start 的时刻（nil = 没发过）。持久化：手机被杀后重启不能对同
    /// 一个窗口重复发 start（手表端幂等，但重复发会把"用户手动停掉"覆盖掉）。
    private static let startIssuedKey = "timed.watch.start_issued_at"
    /// "发了 start 但表端一直没录"提醒只对同一次 start 发一次。
    private var missNotifiedFor: Date?

    private var startIssuedAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Self.startIssuedKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.startIssuedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.startIssuedKey)
            }
        }
    }

    // MARK: - Wiring

    /// From `AppEnvironment.init` — the scheduler needs config + the watch link.
    func configure(configService: ConfigService, watch: WatchSyncService) {
        self.configService = configService
        self.watch = watch
        startHeartbeat()
    }

    /// Call from scenePhase `.active` too — the cheapest way to catch "the
    /// window started while the app sat in the task switcher".
    func evaluate() {
        guard let configService else { return }
        let cfg = configService.config
        guard cfg.timedRecordingEnabled else {
            if startIssuedAt != nil { issueStop(reason: "switch turned off") }
            isTimedRecording = false
            return
        }

        if cfg.timedRecordingAlwaysOn {
            if startIssuedAt == nil {
                issueStart(endsAt: Date().addingTimeInterval(86_400))
                return
            }
            if watch?.isWatchRecording == true {
                isTimedRecording = true
                lastNotice = L10n.TimedRecording.recordingAlwaysOn
            } else if let issued = startIssuedAt {
                if Date().timeIntervalSince(issued) > 86_400 + 300 {
                    // 上一次的兜底停点过了——重开一轮。
                    startIssuedAt = nil
                } else if Date().timeIntervalSince(issued) > 120,
                          missNotifiedFor != issued {
                    missNotifiedFor = issued
                    lastNotice = L10n.TimedRecording.watchNotRecording
                    notifyStartMissed()
                }
            }
            return
        }

        guard Self.inWindow(start: cfg.timedRecordingStart, end: cfg.timedRecordingEnd, at: Date()) else {
            if startIssuedAt != nil {
                issueStop(reason: "window ended")
            }
            isTimedRecording = false
            lastNotice = nil
            return
        }

        // 窗口内。
        if startIssuedAt == nil {
            issueStart(endsAt: Self.windowEnd(start: cfg.timedRecordingStart, end: cfg.timedRecordingEnd, now: Date()))
            return
        }

        // 已经发过 start：跟随手表心跳更新状态；2 分钟还没录上就提醒一次。
        if watch?.isWatchRecording == true {
            isTimedRecording = true
            lastNotice = L10n.TimedRecording.recording
        } else if let issued = startIssuedAt,
                  Date().timeIntervalSince(issued) > 120,
                  missNotifiedFor != issued {
            missNotifiedFor = issued
            lastNotice = L10n.TimedRecording.watchNotRecording
            notifyStartMissed()
        }
    }

    // MARK: - Commands

    private func issueStart(endsAt: Date) {
        startIssuedAt = Date()
        missNotifiedFor = nil
        isTimedRecording = true
        BackgroundKeeper.shared.acquire(.timedRecording)
        watch?.sendTimedRecordCommand(start: true, endsAt: endsAt)
        lastNotice = L10n.TimedRecording.watchCommandSent
        log.notice("timed recording: start command sent, window ends at \(endsAt, privacy: .public)")
    }

    private func issueStop(reason: String) {
        startIssuedAt = nil
        missNotifiedFor = nil
        isTimedRecording = false
        BackgroundKeeper.shared.release(.timedRecording)
        watch?.sendTimedRecordCommand(start: false, endsAt: nil)
        lastNotice = L10n.TimedRecording.watchStopped
        log.notice("timed recording: stop command sent (\(reason, privacy: .public))")
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in TimedRecordingScheduler.shared.evaluate() }
        }
    }

    // MARK: - Window math

    /// "HH:mm" window, midnight-crossing safe ("23:30"–"07:00").
    static func inWindow(start: String, end: String, at date: Date) -> Bool {
        guard let s = minutes(start), let e = minutes(end) else { return false }
        let cal = Calendar.current
        let n = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return s <= e ? (n >= s && n < e) : (n >= s || n < e)
    }

    /// 窗口结束的绝对时刻（给手表的兜底停止时间）。调用时必在窗口内：
    /// · 不跨午夜（09:00–18:00，现在 10:00）→ 今天的结束点就是答案；
    /// · 跨午夜（23:30–07:00）→ 现在 02:00 用今天 07:00，现在 23:45 已过今晨，
    ///   结束点顺延到明天 07:00。所以唯一规则：结束点 <= 现在 就加一天。
    static func windowEnd(start: String, end: String, now: Date) -> Date {
        let cal = Calendar.current
        let e = minutes(end) ?? 7 * 60
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = e / 60
        comps.minute = e % 60
        var end = cal.date(from: comps) ?? now
        if end <= now {
            end = cal.date(byAdding: .day, value: 1, to: end) ?? end
        }
        return end
    }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m)
        else { return nil }
        return h * 60 + m
    }

    // MARK: - Fallback notification

    /// 手表迟迟没录上——提醒用户抬腕把手表 App 打开。无通知权限时静默。
    private func notifyStartMissed() {
        let content = UNMutableNotificationContent()
        content.title = L10n.TimedRecording.missedTitle
        content.body = L10n.TimedRecording.missedBody
        let request = UNNotificationRequest(
            identifier: "timed-recording-missed-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
