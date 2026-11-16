import CoreMotion
import Foundation
import SwiftUI

enum WatchHapticPattern: String, CaseIterable, Identifiable {
    case single
    case double
    case triple
    case singleLong
    case heartbeat
    case crescendo

    var id: String { rawValue }

    var label: String { L10n.Watch.hapticPatternName(rawValue) }
}

/// The two toggles: "shake to start recording" + "double tap to start/stop recording".
///
/// Storing it **separately** from `WatchRingStyleStore` is deliberate: that one's `reset()` is "restore the default
/// appearance", and having "restore default appearance" reset the recording behaviour too would be surprising — the user tapped
/// restore-default on the colour page, and the recording method changed.
final class WatchRecordingPrefs: ObservableObject {
    static let shared = WatchRecordingPrefs()

    private static let key = "watch.shake_to_record.v1"
    /// ★ 2026-10-15 revision six: double tap (pinching index finger and thumb). **A separate key** —
    /// the two gestures misfire in completely different scenarios (shake is "raise and lower the wrist", pinch is "wanting to press but missing"),
    /// and sharing one toggle would turn off one along with the other.
    private static let pinchKey = "watch.pinch_to_record.v1"
    private static let allDayKey = "watch.all_day_recording.v1"
    private static let hapticLevelKey = "watch.haptic_level.v1"
    private static let stopHapticPatternKey = "watch.haptic_stop_pattern.v1"
    private static let alwaysOnFaceKey = "watch.always_on_face.v1"
    private static let startHapticPatternKey = "watch.haptic_start_pattern.v1"
    private static let eyeShapeKey = "watch.eye_shape.v1"
    private static let drowsyEnabledKey = "watch.drowsy.v1"
    private static let drowsyAfterKey = "watch.drowsy_after.v1"
    private static let pupilFollowKey = "watch.pupil_follow.v1"

    /// Defaults **on**: what the user wants is for this action to work right away; if they really think it misfires,
    /// they can turn it off on the settings page (right below the version number).
    @Published var shakeToRecord: Bool {
        didSet { defaults.set(shakeToRecord, forKey: Self.key) }
    }

    /// Defaults **on** (the user specifically asked for this capability).
    ///
    /// ⚠️ Only watchOS 11+ can really turn it off: on 10.1~10.x Double Tap is system behaviour,
    /// with no API to intercept it (see `PrimaryHandGesture`). The settings page only shows this row on 11+,
    /// so as not to offer a switch that does nothing on 10.x.
    @Published var pinchToRecord: Bool {
        didSet { defaults.set(pinchToRecord, forKey: Self.pinchKey) }
    }

    /// ★ 2026-11-02：全天候录音（省电）开关，见 `allDayKey` 的说明。
    @Published var allDayRecording: Bool {
        didSet { defaults.set(allDayRecording, forKey: Self.allDayKey) }
    }

    /// ★ 2026-11-05：起止触感强度 1–5，见 `hapticLevelKey` 的说明。
    /// 越界值夹回 1...5（UserDefaults 手改/旧版本数据兜底）。
    @Published var hapticLevel: Int {
        didSet { defaults.set(hapticLevel, forKey: Self.hapticLevelKey) }
    }

    /// 触感等级夹在 1–5 之间。
    var clampedHapticLevel: Int { min(5, max(1, hapticLevel)) }

    /// ★ 2026-11-05：结束录音的震动花样（`WatchHapticPattern.rawValue`，见模型里的枚举）。
    @Published var stopHapticPattern: String {
        didSet { defaults.set(stopHapticPattern, forKey: Self.stopHapticPatternKey) }
    }

    /// ★ 2026-11-06：常亮暗态下首页显示表情（true，默认）。手机端也可推过来，见
    /// `WatchLinkMessage.alwaysOnFaceKey`。
    @Published var alwaysOnFace: Bool {
        didSet { defaults.set(alwaysOnFace, forKey: Self.alwaysOnFaceKey) }
    }

    /// ★ 2026-11-05 第三轮：启动录音的震动花样，默认"一下"。
    @Published var startHapticPattern: String {
        didSet { defaults.set(startHapticPattern, forKey: Self.startHapticPatternKey) }
    }

    // MARK: ★ 2026-11-06 二轮：让脸"活起来"的四个偏好

    /// 眼睛形状（`BotEyeShape.rawValue`）。手机选择器可换，随上下文推过来。
    @Published var eyeShapeRaw: String {
        didSet { defaults.set(eyeShapeRaw, forKey: Self.eyeShapeKey) }
    }

    /// 长时间没有触摸 → 打瞌睡（半闭眼）→ 再过 8 秒睡着（闭眼、只留呼吸）。
    /// 默认开——"觉得它是个活物"的核心就是这条。任何触摸都会把它惊醒。
    @Published var drowsyEnabled: Bool {
        didSet { defaults.set(drowsyEnabled, forKey: Self.drowsyEnabledKey) }
    }

    /// 多久没触摸开始打瞌睡（秒）。手机端给 15/30/60/120 四档。
    @Published var drowsyAfter: Int {
        didSet { defaults.set(drowsyAfter, forKey: Self.drowsyAfterKey) }
    }

    /// 按住屏幕拖动时眼睛看向手指（借鉴 agent-avatars 的 `followPointer`）。
    @Published var pupilFollow: Bool {
        didSet { defaults.set(pupilFollow, forKey: Self.pupilFollowKey) }
    }

    /// 解码后的眼睛形状；未知值（降级/旧推送）回默认"竖长条"。
    var eyeShape: BotEyeShape {
        BotEyeShape(rawValue: eyeShapeRaw) ?? .tall
    }

    /// 解码后的结束花样；存了未知值（降级/手改）就回默认"两下"。
    var stopPattern: WatchHapticPattern {
        WatchHapticPattern(rawValue: stopHapticPattern) ?? .double
    }

    /// 解码后的启动花样；未知值回默认"一下"。
    var startPattern: WatchHapticPattern {
        WatchHapticPattern(rawValue: startHapticPattern) ?? .single
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ⚠️ Must use `object(forKey:)` to tell "was it ever set": `bool(forKey:)` returns
        // false when the key is absent, so "default on" would silently become "default off", and the user could never
        // turn it on — every cold launch returns to false.
        self.shakeToRecord = (defaults.object(forKey: Self.key) as? Bool) ?? true
        self.pinchToRecord = (defaults.object(forKey: Self.pinchKey) as? Bool) ?? true
        self.allDayRecording = (defaults.object(forKey: Self.allDayKey) as? Bool) ?? false
        self.hapticLevel = (defaults.object(forKey: Self.hapticLevelKey) as? Int) ?? 4
        self.stopHapticPattern = (defaults.object(forKey: Self.stopHapticPatternKey) as? String)
            ?? WatchHapticPattern.double.rawValue
        self.startHapticPattern = (defaults.object(forKey: Self.startHapticPatternKey) as? String)
            ?? WatchHapticPattern.single.rawValue
        self.alwaysOnFace = (defaults.object(forKey: Self.alwaysOnFaceKey) as? Bool) ?? true
        self.eyeShapeRaw = (defaults.object(forKey: Self.eyeShapeKey) as? String)
            ?? BotEyeShape.tall.rawValue
        self.drowsyEnabled = (defaults.object(forKey: Self.drowsyEnabledKey) as? Bool) ?? true
        self.drowsyAfter = (defaults.object(forKey: Self.drowsyAfterKey) as? Int) ?? 45
        self.pupilFollow = (defaults.object(forKey: Self.pupilFollowKey) as? Bool) ?? true
    }
}

/// "Shake the watch hard" detection.
///
/// ## Why the raw accelerometer rather than `deviceMotion.userAcceleration`
/// All we care about is "the wrist got yanked hard". The raw accelerometer's **magnitude** is always 1g at rest
/// (gravity), **rotating** the wrist can't change it (only the direction of gravity in the sensor's coordinate frame changes),
/// and only **translation** pushes the magnitude up — exactly the physical signature of a "shake".
/// So a single `|a| > threshold` criterion suffices, and it also avoids the branch where `deviceMotion` may be
/// unavailable on some models (`userAcceleration` requires an attitude solve first).
///
/// ## Why it requires "two threshold crossings in a row within a time window"
/// Raising and lowering the wrist, tapping the edge of a desk, buckling the strap when putting the watch on — all produce **one** sharp peak;
/// a real "shake twice" necessarily crosses twice in a row within a second. Requiring two costs about 0.1 s
/// of latency in detection, and buys not starting recording by itself while walking or typing.
///
/// ## Why the gyroscope alone won't do
/// The gyroscope only measures angular velocity; a motion like "turn the wrist to look at the watch" has high angular velocity but tiny acceleration,
/// so using it as the criterion would misfire every time you check the time.
final class WatchShakeDetector {
    /// Only crossing this acceleration (in g) counts as one "impact". At rest it's 1g; walking peaks
    /// never reach 2.3, while deliberately flicking the wrist easily exceeds 3g.
    private static let threshold: Double = 2.3
    /// Two impacts must fall within this time window to count as a "shake".
    private static let burstWindow: TimeInterval = 0.9
    /// Goes quiet for a spell after triggering, so one shake isn't split into "on→off→on".
    private static let cooldown: TimeInterval = 2.0
    /// 25Hz is enough to tell "shake" from "bump" (one impact lasts about 100~200ms).
    /// Higher is just wasted power — this page stays on constantly, and the sampling rate is the big item on the battery bill.
    private static let updateInterval: TimeInterval = 1.0 / 25.0

    private let manager = CMMotionManager()
    private var onShake: (() -> Void)?
    /// Impact timestamps along the trace, keeping only those within `burstWindow`.
    private var peaks: [Date] = []
    /// Whether the previous sample was already above the threshold — used to count only the "crossing upward" event.
    private var aboveThreshold = false
    private var lastFire = Date.distantPast

    var isRunning: Bool { manager.isAccelerometerActive }

    /// Start listening. `handler` is called on the **main queue**.
    ///
    /// Idempotent: if it's already running, just swap the handler rather than restarting sampling (restarting re-warms the die,
    /// and the first few tens of milliseconds of data are inaccurate).
    func start(_ handler: @escaping () -> Void) {
        onShake = handler
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        peaks.removeAll()
        aboveThreshold = false
        manager.accelerometerUpdateInterval = Self.updateInterval
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let a = data.acceleration
            self.handle(magnitude: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
        }
    }

    func stop() {
        onShake = nil
        peaks.removeAll()
        aboveThreshold = false
        manager.stopAccelerometerUpdates()
    }

    private func handle(magnitude: Double) {
        guard magnitude > Self.threshold else {
            aboveThreshold = false
            return
        }
        // One impact keeps several consecutive samples above the threshold. Record only on the **first** crossing,
        // otherwise one impact gets counted five or six times and the "two to count as a shake" bar amounts to nothing.
        guard !aboveThreshold else { return }
        aboveThreshold = true

        let now = Date()
        peaks.append(now)
        peaks.removeAll { now.timeIntervalSince($0) > Self.burstWindow }
        guard peaks.count >= 2, now.timeIntervalSince(lastFire) >= Self.cooldown else { return }
        peaks.removeAll()
        lastFire = now
        onShake?()
    }
}
