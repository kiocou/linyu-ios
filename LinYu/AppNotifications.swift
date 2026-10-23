import UserNotifications

final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()
    private let center = UNUserNotificationCenter.current()
    func configure() { center.delegate = self }
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
