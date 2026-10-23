import UserNotifications

final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()
    private let center = UNUserNotificationCenter.current()

    /// 「结束用水」按钮的 action id
    static let stopAction = "LINYU_STOP_ACTION"
    /// 「使用中」通知的分类（带按钮）
    static let inUseCategory = "LINYU_IN_USE"

    func configure() {
        center.delegate = self
        // 对照 Android 通知栏那条「结束用水」按钮。
        // ⚠️ iOS 的通知**不会常驻**、也不能像前台服务那样每秒刷新计时，
        // 所以这里只做到「用中有一条通知 + 一键结束」，这是系统能力的边界。
        let stop = UNNotificationAction(
            identifier: Self.stopAction,
            title: "结束用水",
            // 必须 foreground：后台既连不上蓝牙也发不了关阀请求
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.inUseCategory,
            actions: [stop],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// 开阀成功后挂一条「使用中」通知（对照 Android `Notifier.notifyInUse`）
    func inUse(device: String) {
        guard Prefs.notifyEnabled, Prefs.notifyInUse else { return }
        let name = device.count > 14 ? "…" + String(device.suffix(13)) : device
        let content = UNMutableNotificationContent()
        content.title = "正在使用 · " + name
        content.body = "点开回到使用页；也可以在通知上直接结束用水"
        content.categoryIdentifier = Self.inUseCategory
        content.sound = nil
        center.add(UNNotificationRequest(identifier: "linyu.inUse", content: content, trigger: nil)) { error in
            if let error { AppLog.shared.w("使用中通知发送失败：\(error.localizedDescription)") }
        }
    }

    /// 通知上的按钮点击 —— 只记一个待处理标记，回到前台再执行。
    ///
    /// ⚠️ 不能在回调里直接发关阀请求：CoreBluetooth 和网络在后台都不保证可用，
    /// 而且 App 可能被系统挂起。放到前台执行才可靠。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.stopAction {
            Prefs.pendingStopRequest = true
        } else if response.notification.request.identifier == "linyu.inUse" {
            Prefs.pendingOpenShower = true
        }
        completionHandler()
    }
    func requestPermission() async -> Bool {
        do { return try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { AppLog.shared.w("通知授权失败：\(error.localizedDescription)"); return false }
    }
    func clear() {
        center.removePendingNotificationRequests(withIdentifiers: ["linyu.inUse", "linyu.finished"])
        center.removeDeliveredNotifications(withIdentifiers: ["linyu.inUse", "linyu.finished"])
    }
    func finished(device: String, elapsed: Int, amount: Double?, automatic: Bool) {
        center.removeDeliveredNotifications(withIdentifiers: ["linyu.inUse"])
        guard Prefs.notifyEnabled, automatic ? Prefs.notifyAutoClose : Prefs.notifyFinished else { return }
        let name = device.count > 14 ? "…" + String(device.suffix(13)) : device
        let content = UNMutableNotificationContent()
        content.title = (automatic ? "设备已自动关停 · " : "使用结束 · ") + name
        let duration = elapsed < 60 ? "\(elapsed)秒" : "\(elapsed / 60)分\(elapsed % 60)秒"
        content.body = "用时 \(duration) · " + (amount.map { $0 > 0 ? "消费 \(MoneyFormat.withSymbol($0))" : "无消费" } ?? "结算中")
        if automatic && Prefs.notifyAlert { content.sound = .default }
        center.add(UNNotificationRequest(identifier: "linyu.finished", content: content, trigger: nil)) { error in
            if let error { AppLog.shared.w("通知发送失败：\(error.localizedDescription)") }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Prefs.notifyAlert ? [.banner, .list, .sound] : [.list])
    }
}
