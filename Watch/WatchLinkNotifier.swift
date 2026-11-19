import Foundation
import UserNotifications
import os.log

private let log = Logger(subsystem: "com.nomily.app.watch", category: "notifier")

@MainActor
final class WatchLinkNotifier: NSObject, ObservableObject {
    static let shared = WatchLinkNotifier()

    /// 用户点了通知 / 通知上的「重连」按钮。由 `WatchRecorderModel` 接到 `reconnectNow()`。
    var onReconnectRequest: (() -> Void)?

    /// 同一条通知只保留一个：预约、撤销、替换都用这个 id。
    private static let identifier = "nomily.link.lost"
    private static let categoryIdentifier = "NOMILY_LINK_LOST"
    private static let reconnectAction = "NOMILY_LINK_RECONNECT"

    private let center = UNUserNotificationCenter.current()
    private var authorized = false
    private var asked = false

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [
                    // 长按通知展开后的动作。不带 `.foreground`：点了就地重连，
                    // 不需要把 App 拽到前台（用户可能正忙着，不想被界面打断）。
                    UNNotificationAction(
                        identifier: Self.reconnectAction,
                        title: L10n.Watch.linkLostRetry,
                        options: []
                    )
                ],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    /// 幂等；被用户拒绝过一次就不再骚扰（系统本来也只会问一次）。
    func requestAuthorizationIfNeeded() {
        guard !asked else { return }
        asked = true
        Task { @MainActor in
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                authorized = granted
                log.info("notification authorization: \(granted, privacy: .public)")
            } catch {
                log.error("notification authorization failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 掉线的瞬间调用：预约 `grace` 秒后投递。期间恢复可达就 `cancel()`。
    func scheduleDisconnect(after grace: TimeInterval, body: String, recording: Bool) {
        guard authorized else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, grace), repeats: false)
        add(body: body, recording: recording, trigger: trigger)
    }

    /// 立刻投递（用户已经不看表了——熄屏/退到后台时才有意义）。
    func presentDisconnectNow(body: String, recording: Bool) {
        guard authorized else { return }
        add(body: body, recording: recording, trigger: nil)
    }

    /// 撤掉预约的与已经投递的。可达性恢复、录音结束、用户从通知点进来都会走这里。
    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    private func add(body: String, recording: Bool, trigger: UNNotificationTrigger?) {
        let content = UNMutableNotificationContent()
        content.title = L10n.Watch.linkLostTitle
        content.body = body
        content.categoryIdentifier = Self.categoryIdentifier
        // 录音还在跑的时候给一声；只是"有东西没传完"就别再响一次了。
        if recording { content.sound = .default } else { content.sound = nil }
        // 同 id 重复预约＝替换，不会堆成一串。
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)) { error in
            if let error {
                log.error("notification add failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

extension WatchLinkNotifier: UNUserNotificationCenterDelegate {
    /// App 在前台（含常亮显示）时也要真的弹出来：断联提醒全部意义就在于"看得见"。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            guard identifier == Self.identifier else { return }
            self.cancel()
            self.onReconnectRequest?()
        }
        completionHandler()
    }
}
