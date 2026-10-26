import UserNotifications
import Combine

final class AppNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()
    private let center = UNUserNotificationCenter.current()
    @Published private(set) var actions: [DeviceNotificationAction] = []
    @Published private(set) var permissionDenied = false
    @Published private(set) var authorizationError: String?
    @Published private(set) var settingsRevision = 0
    @Published var destinationTab: Int?
    private var inUseOrders: [String: String] = [:]
    static var accountKey: String { Session.shared.projectId + ":" + Session.shared.accountId }

    func consume(_ id: UUID) { actions.removeAll { $0.id == id } }

    /// 状态提示分类，不提供容器内不可靠的关阀按钮。
    static let inUseCategory = "LINYU_IN_USE"

    func configure() {
        center.delegate = self
        // 旧版通知没有目标身份，不能保留可误导的停止入口。
        center.removePendingNotificationRequests(withIdentifiers: ["linyu.inUse", "linyu.finished"])
        center.removeDeliveredNotifications(withIdentifiers: ["linyu.inUse", "linyu.finished"])
        // 替换旧分类以移除结束按钮；旧版计时通知一并清理，前台按活跃订单重建。
        center.getDeliveredNotifications { values in
            let ids = values.filter {
                ($0.request.content.categoryIdentifier == Self.inUseCategory && $0.request.content.body.hasPrefix("已用 ")) || $0.request.identifier == "linyu.test"
            }.map { $0.request.identifier }
            self.center.removeDeliveredNotifications(withIdentifiers: ids)
        }
        center.removePendingNotificationRequests(withIdentifiers: ["linyu.test"])
        let category = UNNotificationCategory(
            identifier: Self.inUseCategory,
            actions: [],
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
        let snapshot = "\(startedAt):\(orderNo)"
        guard inUseOrders[snCode] != snapshot else { return }
        inUseOrders[snCode] = snapshot
        content.body = "请在应用内查看或结束用水"
        content.categoryIdentifier = Self.inUseCategory
        content.threadIdentifier = "linyu.inUse." + Self.accountKey
        content.userInfo = DeviceNotificationTarget(accountKey: Self.accountKey, snCode: snCode,
                                                    orderNo: orderNo, startedAt: startedAt).userInfo
        content.userInfo["kind"] = NotificationKind.inUse.rawValue
        content.sound = nil
        content.interruptionLevel = .passive
        submit(UNNotificationRequest(identifier: DeviceNotificationTarget.notificationID(snCode: snCode, finished: false), content: content, trigger: nil))
    }

    /// 点击状态通知仅尝试打开原订单；旧版停止 action 一律忽略。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           request.content.userInfo["accountKey"] as? String == Self.accountKey,
           let raw = request.content.userInfo["kind"] as? String,
           let kind = NotificationKind(rawValue: raw), kind != .inUse {
            DispatchQueue.main.async { self.destinationTab = kind.destination; completionHandler() }
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              request.content.categoryIdentifier == Self.inUseCategory,
              let target = DeviceNotificationTarget(userInfo: request.content.userInfo) else {
            completionHandler(); return
        }
        DispatchQueue.main.async {
            self.actions.append(DeviceNotificationAction(target: target, stop: false))
            completionHandler()
        }
    }
    @MainActor func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        let wasDenied = permissionDenied
        permissionDenied = settings.authorizationStatus == .denied
        AppLog.shared.i("通知设置：authorization=\(settings.authorizationStatus.rawValue), alert=\(settings.alertSetting.rawValue), sound=\(settings.soundSetting.rawValue), notificationCenter=\(settings.notificationCenterSetting.rawValue), lockScreen=\(settings.lockScreenSetting.rawValue), bundle=\(Bundle.main.bundleIdentifier ?? "unknown")")
        if wasDenied && (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) {
            authorizationError = nil
            settingsChanged()
        }
    }
    @MainActor func requestPermission() async -> Bool {
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            authorizationError = allowed ? nil : "请在系统设置中允许通知"
            return allowed
        }
        catch {
            await refreshAuthorization()
            recordFailure(error, operation: "通知授权")
            return false
        }
    }

    @MainActor private func recordFailure(_ error: Error, operation: String) {
        let failure = error as NSError
        AppLog.shared.w("\(operation)失败：domain=\(failure.domain), code=\(failure.code), \(failure.localizedDescription)")
        if failure.domain == UNErrorDomain && failure.code == UNError.Code.notificationsNotAllowed.rawValue {
            authorizationError = "通知未授权；容器安装请开启修复本地通知"
        } else {
            authorizationError = "通知失败，请重试"
        }
    }

    /// 所有通知统一记录系统拒绝原因，不能把 add() 无回调当作发送成功。
    private func submit(_ request: UNNotificationRequest) {
        center.add(request) { error in
            guard let error else { return }
            Task { @MainActor in self.recordFailure(error, operation: "通知发送") }
        }
    }

    func clear() {
        inUseOrders.removeAll()
        destinationTab = nil
        actions.removeAll()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
    func clearInUse(snCode: String) {
        inUseOrders[snCode] = nil
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
        content.userInfo["kind"] = (automatic ? NotificationKind.autoClosed : .finished).rawValue
        if let pending = PendingSettlementStore.all().first(where: { $0.snCode == snCode }) {
            content.userInfo["pendingCreatedAt"] = String(pending.createdAt)
        }
        let duration = elapsed < 60 ? "\(elapsed)秒" : "\(elapsed / 60)分\(elapsed % 60)秒"
        content.body = "用时 \(duration) · " + (amount.map { $0 > 0 ? "消费 \(MoneyFormat.withSymbol($0))" : "无消费" } ?? "结算中")
        if automatic && Prefs.notifyAlert { content.sound = .default }
        content.interruptionLevel = automatic && Prefs.notifyAlert ? .active : .passive
        submit(UNNotificationRequest(identifier: DeviceNotificationTarget.notificationID(snCode: snCode, finished: true), content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let kind = (notification.request.content.userInfo["kind"] as? String).flatMap(NotificationKind.init(rawValue:))
        guard kind.map(isEnabled) ?? Prefs.notifyEnabled else { completionHandler([]); return }
        if notification.request.content.userInfo["quietUpdate"] as? Bool == true {
            completionHandler([.list]); return
        }
        completionHandler(kind?.urgent == true && Prefs.notifyAlert ? [.banner, .list, .sound] : [.list])
    }

    /// Android showCloseUnconfirmed/showCloseFailed；不移除使用中通知或停止入口。
    func closeProblem(device: String, snCode: String, reason: String? = nil) {
        guard Prefs.notifyEnabled, Prefs.notifyFinished else { return }
        let name = device.count > 14 ? "…" + String(device.suffix(13)) : device
        let content = UNMutableNotificationContent()
        content.title = (reason == nil ? "关阀状态未确认 · " : "关阀失败 · ") + name
        content.body = reason ?? "网络异常，设备可能仍在用水，请重试"
        content.threadIdentifier = "linyu.finished." + Self.accountKey
        content.userInfo = ["accountKey": Self.accountKey, "kind": NotificationKind.closeProblem.rawValue]
        if Prefs.notifyAlert { content.sound = .default }
        content.interruptionLevel = Prefs.notifyAlert ? .active : .passive
        submit(UNNotificationRequest(identifier: DeviceNotificationTarget.notificationID(snCode: snCode, finished: true), content: content, trigger: nil))
    }

    private func isEnabled(_ kind: NotificationKind) -> Bool {
        kind.enabled(master: Prefs.notifyEnabled, inUse: Prefs.notifyInUse,
                     finished: Prefs.notifyFinished, autoClose: Prefs.notifyAutoClose)
    }

    func settingsChanged() {
        inUseOrders.removeAll()
        settingsRevision += 1
        if !Prefs.notifyEnabled { clear(); return }
        center.getDeliveredNotifications { values in
            DispatchQueue.main.async {
                let ids = values.filter {
                    guard let raw = $0.request.content.userInfo["kind"] as? String,
                          let kind = NotificationKind(rawValue: raw) else { return false }
                    return !self.isEnabled(kind)
                }.map { $0.request.identifier }
                self.center.removeDeliveredNotifications(withIdentifiers: ids)
                self.center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    func openProblem(device: String, snCode: String, reason: String, occupied: Bool) {
        guard Prefs.notifyEnabled else { return }
        let content = UNMutableNotificationContent()
        let kind: NotificationKind = occupied ? .occupied : .openFailed
        let name = device.count > 14 ? "…" + String(device.suffix(13)) : device
        content.title = occupied ? "设备占用中" : "开阀失败 · " + name
        content.body = occupied ? name + "正在被他人使用" : reason
        content.userInfo = ["accountKey": Self.accountKey, "kind": kind.rawValue]
        content.threadIdentifier = "linyu.events." + Self.accountKey
        if Prefs.notifyAlert { content.sound = .default }
        content.interruptionLevel = Prefs.notifyAlert ? .active : .passive
        submit(UNNotificationRequest(identifier: "linyu.openProblem." + snCode, content: content, trigger: nil))
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
                content.interruptionLevel = .passive
                content.userInfo["quietUpdate"] = true
                self.submit(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            }
        }
    }
}
