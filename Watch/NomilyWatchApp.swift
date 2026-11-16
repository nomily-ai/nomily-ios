import SwiftUI
import WatchKit
import os.log

/// Watch companion: record on the wrist when the Nomi isn't with you. Clips
/// sync to the iPhone Library and run through the same transcription pipeline
/// as device recordings.
///
/// There was a second page here that mirrored the Nomi's state and could
/// start/stop it from the wrist. It was removed: the watch has no BLE link of
/// its own, so every answer had to come from the phone, and the phone can only
/// answer usefully when it is already connected — which it often isn't when
/// woken in the background. The page spent most of its life showing a status
/// that was stale, wrong, or "connecting", which is worse than not offering it.


enum WatchBackgroundRefresher {
    static let taskID = "com.nomily.watch.refresh"
    private static let lastScheduledKey = "watch.bgrefresh.last.v1"
    private static let log = Logger(subsystem: "com.nomily.app.watch", category: "bgrefresh")

    /// 排下一次（1 小时后）。**4 小时内已有排程就不叠加**——回前台、后台任务结束
    /// 都会调这里，无脑排会把队列堆满（系统对重复排程的预算惩罚最狠）。
    static func scheduleNext() {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: lastScheduledKey)
        if last > 0, Date().timeIntervalSince1970 - last < 4 * 3600 { return }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(3600),
            userInfo: nil
        ) { error in
            log.error("schedule failed: \(String(describing: error), privacy: .public)")
        }
        defaults.set(Date().timeIntervalSince1970, forKey: lastScheduledKey)
        log.info("background refresh scheduled (+1h)")
    }

    /// 后台任务到达。收件由 WCSession 激活自动完成，这里只续链条。
    static func runOnce() async {
        log.info("background refresh fired")
        scheduleNext()
    }
}

@main
struct NomilyWatchApp: App {
    @StateObject private var language: WatchLanguageStore
    @StateObject private var link: WatchLink
    @StateObject private var recorder: WatchRecorderModel
    /// 定时录音补执行需要感知「App 回到前台」。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Built first: its `init` swaps the string bundle, and every `L10n` read
        // below it depends on that already being in place.
        _language = StateObject(wrappedValue: WatchLanguageStore())
        let link = WatchLink()
        link.activate()
        _link = StateObject(wrappedValue: link)
        let recorder = WatchRecorderModel(link: link)
        _recorder = StateObject(wrappedValue: recorder)
        // ★ 2026-10-30：定时录音（手机 → 手表）。见 WatchLinkMessage.timedRecordCommandKey。
        // start/stop 都幂等（模型里各自有 guard），重复派发无害。
        link.onTimedRecordCommand = { [weak recorder] command, _, endsAt in
            switch command {
            case "start":
                recorder?.startRemotely()
                if let endsAt { recorder?.scheduleRemoteStop(at: endsAt) }
            case "stop":
                if WatchRecordingPrefs.shared.allDayRecording {
                    recorder?.cancelRemoteStop()
                } else {
                    recorder?.stop()
                    recorder?.cancelRemoteStop()
                }
            default:
                break
            }
        }
        link.onAllDaySetting = { [weak recorder] on in
            guard WatchRecordingPrefs.shared.allDayRecording != on else { return }
            WatchRecordingPrefs.shared.allDayRecording = on
            recorder?.setPowerSaver(on)
            if on {
                recorder?.autoStartForAllDayIfNeeded()
            } else {
                recorder?.stop()
            }
        }
        // ★ 2026-11-06（表情常亮开关）：手机上翻的开关落到手表偏好。
        // 只影响暗显时首页画不画表情，不碰录音模型，无需其他动作。
        link.onAlwaysOnFaceSetting = { on in
            guard WatchRecordingPrefs.shared.alwaysOnFace != on else { return }
            WatchRecordingPrefs.shared.alwaysOnFace = on
        }
        // ★ 2026-11-06（声纹注册回执）：手机注册完成（成败都回）→ 落到共享状态，
        // 声纹页据此把"已发送"换成"已更新/失败"，并把开始按钮换掉。
        // 状态单例是 MainActor，这里跳一跳（回调源头是 WCSession 的任务链）。
        link.onVoiceprintResult = { id, ok in
            Task { @MainActor in
                WatchVoiceprintEnrollState.shared.apply(resultID: id, ok: ok)
            }
        }
        // ★ 2026-11-06 二轮（"让脸活起来"四设置）：手机上改 → 落手表偏好。
        // 只在值真的变了时写，避免无谓的UserDefaults写入与页面重绘。
        link.onEyeShapeSetting = { raw in
            guard WatchRecordingPrefs.shared.eyeShapeRaw != raw else { return }
            WatchRecordingPrefs.shared.eyeShapeRaw = raw
        }
        link.onDrowsySetting = { enabled, after in
            guard WatchRecordingPrefs.shared.drowsyEnabled != enabled
                    || WatchRecordingPrefs.shared.drowsyAfter != after else { return }
            WatchRecordingPrefs.shared.drowsyEnabled = enabled
            WatchRecordingPrefs.shared.drowsyAfter = after
        }
        link.onPupilFollowSetting = { on in
            guard WatchRecordingPrefs.shared.pupilFollow != on else { return }
            WatchRecordingPrefs.shared.pupilFollow = on
        }
    }

    var body: some Scene {
        WindowGroup {
            LocalizedWatchRoot()
                .environmentObject(language)
                .environmentObject(link)
                .environmentObject(recorder)
                // ★ 2026-11-03 八轮：电量采样从**启动**就开始，不等用户打开电量页。
                //   旧算法要十分钟起步，等打开页面才采等于每次进去都是「Collecting…」；
                //   九轮换成回归 + 累计掉电后门槛降了，但**样本越多越准**这条没变。
                //   `start()` 幂等，抬腕回前台再补一条（后台期间定时器是停的）。
                // ★ 2026-11-04 九轮：顺手把录音状态对一次——App 被系统杀掉后靠
                //   workout 恢复录音时，`isRecording` 的 didSet 不会重放，不对的话
                //   这一整段录音的样本会被记成"待机"。
                .onAppear {
                    WatchBatteryMonitor.shared.isRecording = recorder.isRecording
                    WatchBatteryMonitor.shared.start()
                    // ★ 2026-11-06：App 一启动就给自己排下一次后台刷新——
                    // 之后由每次后台任务醒来续链（见 WatchBackgroundRefresher）。
                    WatchBackgroundRefresher.scheduleNext()
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    recorder.consumePendingToggle()
                    link.retryUnconfirmedTimedCommand { recorder.remoteStartPending }
                    WatchBatteryMonitor.shared.refresh()
                }
        }
        // ★ 2026-11-06：系统按排程唤醒 App 时走这里。收件（applicationContext /
        // userInfo / 待传回执）由 App init 里的 `link.activate()` 幂等激活会话后
        // 经 WCSession 回调自动完成；这里只负责续排下一次。
        .backgroundTask(.appRefresh(WatchBackgroundRefresher.taskID)) {
            await WatchBackgroundRefresher.runOnce()
        }
    }
}
