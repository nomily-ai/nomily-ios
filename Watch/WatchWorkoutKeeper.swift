import Foundation
import HealthKit
import WatchKit
import os.log

private let log = Logger(subsystem: "com.nomily.app.watch", category: "workout-keeper")

@MainActor
final class WatchWorkoutKeeper {

    static let shared = WatchWorkoutKeeper()

    private var session: HKWorkoutSession?
    private var healthStore = HKHealthStore()
    /// 授权问过一次就不再问（`notDetermined` 才会弹系统框）。
    private var authRequested = false

    /// 麦克风授权通过后调用一次（幂等）。拒绝也不影响录音——只是保活降级。
    func requestAuthorizationIfNeeded() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard !authRequested else { return }
        authRequested = true
        healthStore.requestAuthorization(toShare: [.workoutType()], read: []) { granted, error in
            // 后台队列回调：只打日志，授权结果不阻塞录音。
            if let error {
                log.warning("HealthKit auth error: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("HealthKit auth granted=\(granted, privacy: .public)")
            }
        }
    }

    /// 开录时调用。失败静默（录音不受影响），原因进日志。
    func start() {
        guard HKHealthStore.isHealthDataAvailable() else {
            log.warning("workout keeper: HealthKit unavailable — background keep-alive degraded")
            return
        }
        guard session == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .other          // 录音不是运动；`.other` 是诚实的选择
        config.locationType = .indoor
        do {
            let workout = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            workout.startActivity(with: Date())
            session = workout
            log.info("workout keeper: session started")
        } catch {
            // 最常见的失败原因：HealthKit 授权还没批下来（首次录音授权是异步的）。
            // 下次开录就正常了；本次退回"无保活"的老路径。
            log.warning("workout keeper: session refused (\(error.localizedDescription, privacy: .public)) — degraded")
        }
    }

    /// 停录时调用。workout 不落库（没挂 builder，`end()` 后系统不留痕）。
    func stop() {
        guard let session else { return }
        self.session = nil
        session.end()
        log.info("workout keeper: session ended")
    }
}
