import UserNotifications
import Combine

final class AppNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()
    private let center = UNUserNotificationCenter.current()
    @Published private(set) var actions: [DeviceNotificationAction] = []
    static var accountKey: String { Session.shared.projectId + ":" + Session.shared.accountId }

    func consume(_ id: UUID) { actions.removeAll { $0.id == id } }

    /// 「结束用水」按钮的 action id
    static let stopAction = "LINYU_STOP_ACTION"
    /// 「使用中」通知的分类（带按钮）
    static let inUseCategory = "LINYU_IN_USE"

    func configure() {
        center.delegate = self
        // 旧版通知没有目标身份，不能保留可误导的停止入口。
        center.removePendingNotificationRequests(withIdentifiers: ["linyu.inUse", "linyu.finished"])
        center.removeDeliveredNotifications(withIdentifiers: ["linyu.inUse", "linyu.finished"])
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
    func inUse(device: String, snCode: String, orderNo: String, startedAt: Int64) {
        guard Prefs.notifyEnabled, Prefs.notifyInUse else { return }
        let name = device.count > 14 ? "…" + String(device.suffix(13)) : device
        let content = UNMutableNotificationContent()
        content.title = "正在使用 · " + name
        content.body = "点开回到使用页；也可以在通知上直接结束用水"
        content.categoryIdentifier = Self.inUseCategory
        content.threadIdentifier = "linyu.inUse." + Self.accountKey
        content.userInfo = DeviceNotificationTarget(accountKey: Self.accountKey, snCode: snCode,
                                                    orderNo: orderNo, startedAt: startedAt).userInfo
        content.sound = nil
        center.add(UNNotificationRequest(identifier: DeviceNotificationTarget.notificationID(snCode: snCode, finished: false), content: content, trigger: nil)) { error in
            if let error { AppLog.shared.w("使用中通知发送失败：\(error.localizedDescription)") }
        }
    }

    /// 通知上的按钮点击 —— 排队保存原设备与订单身份，回到前台再执行。
    ///
    /// ⚠️ 不能在回调里直接发关阀请求：CoreBluetooth 和网络在后台都不保证可用，
    /// 而且 App 可能被系统挂起。放到前台执行才可靠。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        guard response.actionIdentifier == Self.stopAction ||
                (response.actionIdentifier == UNNotificationDefaultActionIdentifier &&
                 request.content.categoryIdentifier == Self.inUseCategory),
              let target = DeviceNotificationTarget(userInfo: request.content.userInfo) else {
            completionHandler(); return
        }
        DispatchQueue.main.async {
            self.actions.append(DeviceNotificationAction(target: target, stop: response.actionIdentifier == Self.stopAction))
            completionHandler()
        }
    }
    func requestPermission() async -> Bool {
        do { return try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { AppLog.shared.w("通知授权失败：\(error.localizedDescription)"); return false }
    }
    func clear() {
        actions.removeAll()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
    func clearInUse(snCode: String) {
        let id = DeviceNotificationTarget.notificationID(snCode: snCode, finished: false)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
    func finished(device: String, snCode: String, elapsed: Int, amount: Double?, automatic: Bool) {
        // 使用中通知在确认关阀时撤销，不能等异步结算返回再删：同设备可能已开新单。
        guard Prefs.notifyEnabled, automatic ? Prefs.notifyAutoClose : Prefs.notifyFinished else { return }
        let name = device.count > 14 ? "…" + String(device.suffix(13)) : device
        let content = UNMutableNotificationContent()
        content.title = (automatic ? "设备已自动关停 · " : "使用结束 · ") + name
        content.threadIdentifier = "linyu.finished." + Self.accountKey
        content.userInfo["accountKey"] = Self.accountKey
        content.userInfo["automatic"] = automatic
        if let pending = PendingSettlementStore.all().first(where: { $0.snCode == snCode }) {
            content.userInfo["pendingCreatedAt"] = String(pending.createdAt)
        }
        let duration = elapsed < 60 ? "\(elapsed)秒" : "\(elapsed / 60)分\(elapsed % 60)秒"
        content.body = "用时 \(duration) · " + (amount.map { $0 > 0 ? "消费 \(MoneyFormat.withSymbol($0))" : "无消费" } ?? "结算中")
        if automatic && Prefs.notifyAlert { content.sound = .default }
        center.add(UNNotificationRequest(identifier: DeviceNotificationTarget.notificationID(snCode: snCode, finished: true), content: content, trigger: nil)) { error in
            if let error { AppLog.shared.w("通知发送失败：\(error.localizedDescription)") }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.userInfo["quietUpdate"] as? Bool == true {
            completionHandler([.list]); return
        }
        completionHandler(Prefs.notifyAlert ? [.banner, .list, .sound] : [.list])
    }

    /// Android showCloseUnconfirmed/showCloseFailed；不移除使用中通知或停止入口。
    func closeProblem(device: String, snCode: String, reason: String? = nil) {
        guard Prefs.notifyEnabled, Prefs.notifyFinished else { return }
        let name = device.count > 14 ? "…" + String(device.suffix(13)) : device
        let content = UNMutableNotificationContent()
        content.title = (reason == nil ? "关阀状态未确认 · " : "关阀失败 · ") + name
        content.body = reason ?? "网络异常，设备可能仍在用水，请重试"
        content.threadIdentifier = "linyu.finished." + Self.accountKey
        if Prefs.notifyAlert { content.sound = .default }
        center.add(UNNotificationRequest(identifier: DeviceNotificationTarget.notificationID(snCode: snCode, finished: true), content: content, trigger: nil))
    }

    /// 只更正仍存在、确属该笔待对账的通知；不复活用户已划掉的通知。
    func correctSettlement(_ pending: PendingSettlement, amount: Double) {
        guard Prefs.notifyEnabled else { return }
        let account = Self.accountKey
        let generation = Session.shared.requestGeneration
        let id = DeviceNotificationTarget.notificationID(snCode: pending.snCode, finished: true)
        center.getDeliveredNotifications { notifications in
            DispatchQueue.main.async {
                guard SessionWork.isCurrent(generation), Self.accountKey == account,
                      !ActiveOrderStore.isRunning(pending.snCode),
                      let notification = notifications.first(where: { $0.request.identifier == id }),
                      notification.request.content.userInfo["accountKey"] as? String == account,
                      let stamp = notification.request.content.userInfo["pendingCreatedAt"] as? String,
                      let createdAt = Int64(stamp),
                      SettlementNoticePolicy.shouldCorrect(createdAt: pending.createdAt, notificationCreatedAt: createdAt,
                        now: Int64(Date().timeIntervalSince1970 * 1000)),
                      let content = notification.request.content.mutableCopy() as? UNMutableNotificationContent else { return }
                let automatic = content.userInfo["automatic"] as? Bool ?? false
                guard Prefs.notifyEnabled, automatic ? Prefs.notifyAutoClose : Prefs.notifyFinished else { return }
                let seconds = max(0, pending.elapsedSec)
                let duration = seconds < 60 ? "\(seconds)秒" : "\(seconds / 60)分\(seconds % 60)秒"
                content.body = "用时 \(duration) · " + (amount > 0 ? "消费 \(MoneyFormat.withSymbol(amount))" : "无消费")
                content.sound = nil
                content.userInfo["quietUpdate"] = true
                self.center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            }
        }
    }
}
