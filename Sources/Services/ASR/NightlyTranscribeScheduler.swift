import Foundation
import BackgroundTasks
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "backlog")

@MainActor
final class NightlyTranscribeScheduler {

    /// Registered in project.yml (`BGTaskSchedulerPermittedIdentifiers`) — the
    /// plist entry and this string must match exactly or `submit` throws.
    static let taskIdentifier = "com.nomily.app.transcription.backlog"

    static let shared = NightlyTranscribeScheduler()

    /// Set by `configure`; nil until the composition root has run (the register
    /// path may fire first, in `NomilyApp.init`). The handler no-ops until then.
    private weak var transcription: TranscriptionService?
    private weak var configService: ConfigService?

    /// Whether a handler is currently running the backlog. BGTask execution is
    /// at most once at a time, but the launch-time `schedule()` can land in the
    /// same process as a running handler — this keeps `schedule` idempotent.
    private var isRunning = false

    private init() {}

    // MARK: - Lifecycle

    /// Call from `NomilyApp.init` — the only point where registration is legal.
    /// Returns false if iOS refused (e.g. the identifier is missing from the
    /// plist the binary shipped with), which is logged and otherwise harmless.
    @discardableResult
    static func register() -> Bool {
        let ok = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                await NightlyTranscribeScheduler.shared.handle(task as! BGProcessingTask)
            }
        }
        if !ok {
            log.error("BGTask registration refused for \(Self.taskIdentifier, privacy: .public)")
        }
        return ok
    }

    /// Call from `AppEnvironment.init` once the services exist.
    func configure(transcription: TranscriptionService, configService: ConfigService) {
        self.transcription = transcription
        self.configService = configService
    }

    /// Submit the request for the next window. Cheap and idempotent — called at
    /// launch and on every transition to background. iOS replaces the pending
    /// request with the newest one each time.
    func schedule() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        // Night-shift semantics, both deliberate:
        //   · external power — a batch of uploads is not something to do on
        //     battery at 3am; the user charges the phone overnight anyway.
        //   · network required — the primary market is cloud ASR; waking up for
        //     an offline window would burn the one launch we get on guaranteed
        //     failures (on-device ASR still runs via the foreground paths).
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Self.nextNightWindow()
        do {
            try BGTaskScheduler.shared.submit(request)
            let earliest = Self.nextNightWindow()
            let stamp = DateFormatter.localizedString(from: earliest, dateStyle: .short, timeStyle: .short)
            log.notice("backlog task scheduled, earliest \(stamp, privacy: .public)")
        } catch {
            // Not fatal in the simulator (BGTaskScheduler is a no-op there) or
            // when background refresh is off system-wide — both land here.
            log.error("BGTask submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Execution

    /// The task body. Discovers the backlog, feeds it to the queue, then waits
    /// out the drain before telling iOS we're done.
    private func handle(_ task: BGProcessingTask) async {
        isRunning = true
        defer { isRunning = false }

        // ★ The expiration handler must be set *synchronously*, before any
        // await — iOS calls it on an arbitrary thread and gives no second
        // chance. Hop back to the main actor for the (main-actor) service.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                log.notice("backlog task expired — queue persists for the next launch")
                self?.isRunning = false
                // The drain loop is cut by the process suspension that follows;
                // nothing to roll back — `PendingJob`s are already on disk.
            }
        }

        guard let transcription, let configService else {
            task.setTaskCompleted(success: false)
            schedule() // re-arm for tomorrow even though this window was wasted
            return
        }

        // Respect the switch at execution time, not just schedule time — the
        // user may have turned it off after the request was accepted.
        guard configService.config.nightlyTranscribeEnabled else {
            task.setTaskCompleted(success: true)
            return
        }

        let backlogged = Self.findBacklog()
        guard !backlogged.isEmpty else {
            log.notice("backlog empty — nothing to do tonight")
            task.setTaskCompleted(success: true)
            return
        }
        log.notice("backlog has \(backlogged.count) clips — feeding the queue")

        for url in backlogged {
            transcription.enqueue(fileURL: url)
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)

        // Hand the work to the existing drain loop and stay alive while it
        // runs — the BGTask window closes the moment we `setTaskCompleted`.
        // Waiting on the queue to empty (with a soft floor so a stream of
        // `attempts == maxAttempts` failures can't pin the window open all
        // night) is the closest we get to "drain finished" without new API
        // on TranscriptionService.
        let startedAt = Date()
        while !transcription.pending.isEmpty,
              Date().timeIntervalSince(startedAt) < Self.maxRuntime
        {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let remaining = transcription.pending.count
        log.notice("backlog window closing, \(remaining) still queued")
        task.setTaskCompleted(success: remaining == 0)
        schedule() // whatever is left gets the next night
    }

    // MARK: - Backlog discovery

    /// Audio files in `decryptedDir` with no transcript sibling — the same
    /// "artefact exists ⇒ transcribed" convention `LibraryScanner` uses.
    static func findBacklog() -> [URL] {
        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        let audioExtensions: Set<String> = ["m4a", "aac", "wav", "caf", "mp3", "aif", "aiff", "flac"]
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .compactMap { name -> URL? in
                let base = (name as NSString).deletingPathExtension
                let txt = dir.appendingPathComponent("\(base).txt")
                return fm.fileExists(atPath: txt.path) ? nil : dir.appendingPathComponent(name)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Helpers

    /// Next local 02:00 (or now+3h if it's already past midnight into the
    /// early hours — iOS clamps anyway, this just avoids "today 02:00" being
    /// in the past and being rejected or run immediately).
    private static func nextNightWindow() -> Date {
        var cal = Calendar.current
        cal.timeZone = .current
        let next2am = cal.nextDate(
            after: Date(),
            matching: DateComponents(hour: 2, minute: 0),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(6 * 3600)
        return max(next2am, Date().addingTimeInterval(3 * 3600))
    }

    /// Soft ceiling for one window: hand the remaining work back to the queue's
    /// own persistence rather than pinning the process until iOS force-expires.
    private static let maxRuntime: TimeInterval = 25 * 60
}
