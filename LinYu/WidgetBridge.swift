import Foundation
import Combine
import WidgetKit

/// Android WidgetBridge 的同一职责：发布展示快照，控制仍交给已有水控链。
/// App Group 不保存登录令牌、手机号或密码。
@MainActor final class WidgetBridge: ObservableObject {
    static let shared = WidgetBridge()
    @Published private(set) var command: WidgetCommand?
    private var handling = false
    private var lastReload = Date.distantPast
    private var lastSnapshot: WidgetSnapshot?
    private var consumed: Set<String> = []

    func receive(_ url: URL) {
        guard let request = WidgetCommand(url: url) else { return }
        guard command == nil, !handling else { return }
        command = request
    }
    func clear() {
        command = nil
        consumed.removeAll()
        lastSnapshot = nil
        WidgetSharedStore.write(WidgetSnapshot())
        WidgetCenter.shared.reloadAllTimelines()
    }
    func sync(store: AppDataStore, flow: ShowerFlow, scanner: BLEScanner, force: Bool = false) {
        guard Session.shared.isLoggedIn else { clear(); return }
        let previous = lastSnapshot ?? WidgetSharedStore.read()
        var next = WidgetSnapshot()
        next.owner = AppNotifications.accountKey
        next.lastDevice = Prefs.lastDeviceSnCode
        next.balanceTitle = BalanceEstimator.title
        next.balance = BalanceEstimator.format(BalanceEstimator.estimate(store.bills))
        next.busy = flow.controlBusy || handling
        next.message = flow.isStarting ? "正在开启…" : flow.isStopping ? "正在关闭…" : handling ? "正在处理…" : nil
        let orders = ActiveOrderStore.all()
        var infos: [String: WidgetDevice] = [:]
        for (sn, info) in store.deviceInfos {
            infos[sn] = WidgetDevice(id: sn, name: info.displayName, detail: info.typeLabel, emoji: info.typeEmoji,
                                    selectable: DeviceInfo.inSameRoom(boundKey: Prefs.boundRoom, deviceName: info.deviceName ?? ""))
        }
        if !Prefs.lastDeviceSnCode.isEmpty, infos[Prefs.lastDeviceSnCode] == nil {
            infos[Prefs.lastDeviceSnCode] = WidgetDevice(id: Prefs.lastDeviceSnCode, name: Prefs.lastDeviceName,
                detail: Prefs.lastDeviceTypeName, emoji: Prefs.lastDeviceEmoji,
                selectable: DeviceInfo.inSameRoom(boundKey: Prefs.boundRoom, deviceName: Prefs.lastDeviceRawName))
        }
        for order in orders where infos[order.snCode] == nil {
            infos[order.snCode] = WidgetDevice(id: order.snCode, name: order.deviceName, detail: "使用中的设备", emoji: order.deviceEmoji)
        }
        for item in scanner.devices.sorted(by: { $0.rssi > $1.rssi }) {
            guard let sn = item.parsedSnCode, infos[sn] != nil else { continue }
            infos[sn]?.rssi = item.rssi
            if !next.nearbyIDs.contains(sn) { next.nearbyIDs.append(sn) }
        }
        if scanner.devices.isEmpty, previous.owner == next.owner {
            next.nearbyIDs = previous.nearbyIDs.filter { infos[$0] != nil }
            next.nearbyDate = previous.nearbyDate
        } else { next.nearbyDate = scanner.devices.map(\.lastSeen).max() }
        for sn in Array(infos.keys) {
            infos[sn]?.occupied = flow.deviceOwner[sn] == false
            infos[sn]?.lastConsume = Prefs.lastConsumeFor(sn)
            if let order = orders.first(where: { $0.snCode == sn }) {
                infos[sn]?.running = true
                infos[sn]?.orderNo = order.orderNo
                infos[sn]?.startedAt = Prefs.startedAt(sn)
                infos[sn]?.preDeduct = order.preDeduct
            }
        }
        next.devices = infos.values.sorted { $0.id < $1.id }
        next.bills = store.bills.prefix(5).map { WidgetBill(name: $0.displayNamePart, emoji: $0.deviceEmoji,
             time: $0.consumeDate ?? "", money: $0.yuan.map { "-" + MoneyFormat.withSymbol($0) } ?? "—") }
        let identityChanged = previous.controlIdentity != next.controlIdentity
        next.token = identityChanged ? UUID().uuidString : previous.token
        // 不为每秒计时生成新快照，WidgetKit 使用开始时间自行渲染时间文本。
        next.date = previous.date
        if next != previous {
            next.date = Date()
            guard WidgetSharedStore.write(next) else {
                if lastSnapshot == nil { AppLog.shared.w("小组件共享权限不可用，请保留扩展及应用组签名") }
                return
            }
            lastSnapshot = next
        }
        if force || identityChanged || Date().timeIntervalSince(lastReload) > 15 {
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// URL 只承接已经渲染的组件按钮；校验随机身份、账号、设备、订单，防止旧按钮操作新单。
    func process(store: AppDataStore, flow: ShowerFlow, scanner: BLEScanner) async -> WidgetCommandKind? {
        guard !handling, !flow.controlBusy, let request = command else { return nil }
        command = nil
        guard Session.shared.isLoggedIn else { return .home }
        let snapshot = WidgetSharedStore.read()
        guard request.matches(snapshot), request.owner == AppNotifications.accountKey else {
            flow.toast = "组件已过期，请刷新"
            sync(store: store, flow: flow, scanner: scanner, force: true)
            return .home
        }
        if request.kind == .home || request.kind == .bills || request.kind == .nearby { return request.kind }
        let generation = Session.shared.requestGeneration
        let actionID = "\(request.token):\(request.kind.rawValue):\(request.sn)"
        guard !consumed.contains(actionID) else { flow.toast = "请刷新组件后重试"; return .home }
        consumed.insert(actionID)
        handling = true
        defer {
            handling = false
            if SessionWork.isCurrent(generation) {
                var updated = WidgetSharedStore.read()
                updated.token = UUID().uuidString
                WidgetSharedStore.write(updated)
                lastSnapshot = updated
                consumed.removeAll()
            }
            sync(store: store, flow: flow, scanner: scanner, force: true)
        }
        if request.kind == .refresh {
            await flow.reconcileOnResume()
            await store.reload()
            return .home
        }
        do {
            guard let info = try await DeviceLookup.load(request.sn) else { flow.toast = "设备不存在"; return .home }
            guard SessionWork.isCurrent(generation) else { return nil }
            await store.putDeviceInfo(info, sn: request.sn)
            if request.kind == .start {
                guard ActiveOrderStore.find(request.sn) == nil,
                      DeviceInfo.inSameRoom(boundKey: Prefs.boundRoom, deviceName: info.deviceName ?? "") else {
                    flow.toast = "设备状态已变化，请刷新"; return .home
                }
            }
            let needsBLE = info.needsBluetoothControl || Prefs.isBleDevice(request.sn)
            if needsBLE, scanner.peripheral(forSn: request.sn) == nil {
                scanner.start()
                for _ in 0..<30 {
                    guard SessionWork.isCurrent(generation) else { return nil }
                    if scanner.peripheral(forSn: request.sn) != nil { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard scanner.peripheral(forSn: request.sn) != nil else { flow.toast = "未找到设备，请靠近后重试"; return .nearby }
            }
            guard SessionWork.isCurrent(generation) else { return nil }
            if request.kind == .stop {
                let target = DeviceNotificationTarget(accountKey: request.owner, snCode: request.sn,
                                                      orderNo: request.orderNo, startedAt: request.startedAt)
                _ = await flow.handleNotification(DeviceNotificationAction(target: target, stop: true))
            } else {
                await flow.open(device: info, peripheral: scanner.peripheral(forSn: request.sn), central: scanner.manager)
            }
        } catch { flow.toast = LoginFeedback.message(error) }
        return .home
    }
}
