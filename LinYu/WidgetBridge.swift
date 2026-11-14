import Foundation
import Combine
import WidgetKit

/// Android WidgetBridge 的同一职责：发布展示快照，控制仍交给已有水控链。
/// App Group 不保存登录令牌、手机号或密码。
@MainActor final class WidgetBridge: ObservableObject {
    static let shared = WidgetBridge()
    @Published private(set) var command: WidgetCommand?
    @Published var pendingDeviceSN: String?
    @Published var pendingBillID: String?
    @Published private(set) var operationMessage: String?
    private var acceptedSnapshot: WidgetSnapshot?
    private var handling = false
    private var lastReload = Date.distantPast
    private var needsReload = false
    private var reloadTask: Task<Void, Never>?
    private var lastSnapshot: WidgetSnapshot?
    private var consumed: Set<String> = []
    private var delivery = WidgetDeliveryPolicy()

    func receive(_ url: URL) {
        guard let request = WidgetCommand(url: url) else { return }
        AppLog.shared.i("收到组件入口：\(request.kind.rawValue)，目标 \(request.sn)")
        guard delivery.accept(request, pending: command, handling: handling) else {
            AppLog.shared.i("忽略重复或忙碌中的组件入口：\(request.kind.rawValue)")
            return
        }
        // 在接到点击时保留身份；回前台刷新台账不能把已受理动作变成“旧按钮”。
        acceptedSnapshot = WidgetSharedStore.read()
        command = request
    }
    func enteredBackground() { delivery.enteredBackground() }
    func clear() {
        command = nil
        acceptedSnapshot = nil
        pendingDeviceSN = nil
        pendingBillID = nil
        operationMessage = nil
        consumed.removeAll()
        delivery = WidgetDeliveryPolicy()
        lastSnapshot = nil
        needsReload = false
        reloadTask?.cancel()
        reloadTask = nil
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
        let billSnapshots = store.bills.map { WidgetBill(name: $0.displayNamePart, emoji: $0.deviceEmoji,
            time: $0.consumeDate ?? "", money: $0.yuan.map { "-" + MoneyFormat.withSymbol($0) } ?? "—",
            id: $0.id, deviceSN: $0.deviceSnCode, detail: $0.deviceTypeLabel, amount: $0.yuan) }
        // 冷启动台账尚未补齐时保留同账号的展示缓存；运行状态仍以当前订单台账为准。
        var infos: [String: WidgetDevice] = [:]
        if previous.owner == next.owner {
            for var item in previous.devices {
                item.running = false; item.orderNo = ""; item.startedAt = 0
                infos[item.id] = item
            }
        }
        // 使用中的订单本身就持有完整台账，发布状态不能依赖附近扫描。
        var deviceInfos = store.deviceInfos
        if let active = flow.activeOrder { deviceInfos[active.snCode] = active.device }
        for (address, info) in deviceInfos.sorted(by: { $0.key < $1.key }) {
            let sn = info.snCode.flatMap { $0.isEmpty ? nil : $0 } ?? address
            var item = infos[sn] ?? WidgetDevice(id: sn, name: info.displayName, detail: info.typeLabel, emoji: info.typeEmoji)
            item.name = info.displayName; item.detail = info.typeLabel; item.emoji = info.typeEmoji
            item.selectable = DeviceInfo.inSameRoom(boundKey: Prefs.boundRoom, deviceName: info.deviceName ?? "")
            item.aliases = Array(Set((item.aliases ?? []) + [address, sn])).sorted()
            infos[sn] = item
        }
        if let canonical = infos.values.first(where: { $0.id == next.lastDevice || ($0.aliases ?? []).contains(next.lastDevice) }) {
            next.lastDevice = canonical.id
        }
        if !next.lastDevice.isEmpty, deviceInfos.values.allSatisfy({ $0.snCode != next.lastDevice }) {
            // 覆盖旧快照的筛选结果：即使没有扫描到，持久化的上次设备也可独立展示。
            var last = infos[next.lastDevice] ?? WidgetDevice(id: next.lastDevice, name: Prefs.lastDeviceName,
                detail: Prefs.lastDeviceTypeName, emoji: Prefs.lastDeviceEmoji,
                selectable: DeviceInfo.inSameRoom(boundKey: Prefs.boundRoom, deviceName: Prefs.lastDeviceRawName))
            last.name = Prefs.lastDeviceName; last.detail = Prefs.lastDeviceTypeName; last.emoji = Prefs.lastDeviceEmoji
            last.selectable = DeviceInfo.inSameRoom(boundKey: Prefs.boundRoom, deviceName: Prefs.lastDeviceRawName)
            last.aliases = Array(Set((last.aliases ?? []) + [Prefs.lastDeviceMac, Prefs.lastDeviceSnCode].filter { !$0.isEmpty })).sorted()
            infos[next.lastDevice] = last
        }
        for order in orders where infos[order.snCode] == nil {
            infos[order.snCode] = WidgetDevice(id: order.snCode, name: order.deviceName, detail: "使用中的设备", emoji: order.deviceEmoji,
                aliases: [order.deviceMac].filter { !$0.isEmpty })
        }
        for item in scanner.devices.sorted(by: { $0.rssi > $1.rssi }) {
            guard let address = item.parsedSnCode else { continue }
            let sn = store.deviceInfos[address]?.snCode.flatMap { $0.isEmpty ? nil : $0 } ?? address
            guard infos[sn] != nil else { continue }
            infos[sn]?.rssi = item.rssi
            if !next.nearbyIDs.contains(sn) { next.nearbyIDs.append(sn) }
        }
        if scanner.devices.isEmpty, previous.owner == next.owner {
            next.nearbyIDs = previous.nearbyIDs.filter { infos[$0] != nil }
            next.nearbyDate = previous.nearbyDate
        } else { next.nearbyDate = scanner.devices.map(\.lastSeen).max() }
        for sn in Array(infos.keys) {
            infos[sn]?.occupied = flow.deviceOwner[sn] == false
            if let item = infos[sn] {
                let cached = Prefs.lastConsumeFor(sn)
                let legacy = (item.aliases ?? []).map { Prefs.lastConsumeFor($0) }.first { $0 > 0 } ?? 0
                infos[sn]?.lastConsume = WidgetDisplayPolicy.lastConsume(cached: cached > 0 ? cached : legacy, device: item, bills: billSnapshots)
            }
            if let order = orders.first(where: { $0.snCode == sn }) {
                infos[sn]?.running = true
                infos[sn]?.orderNo = order.orderNo
                infos[sn]?.startedAt = Prefs.startedAt(sn)
                infos[sn]?.preDeduct = PreDeductPolicy.resolve(
                    device: deviceInfos[sn]?.withholdYuan,
                    savedOrder: order.preDeduct,
                    lastDevice: sn == next.lastDevice ? Prefs.lastDeviceWithholdMoney : nil)
            }
        }
        next.devices = infos.values.sorted { $0.id < $1.id }
        next.bills = Array(billSnapshots.prefix(5))
        let identityChanged = previous.controlIdentity != next.controlIdentity
        // 登录会话级身份；别的设备变化/普通刷新不能作废上次设备按钮。
        next.token = previous.owner == next.owner ? previous.token : UUID().uuidString
        // 不为每秒计时生成新快照，WidgetKit 使用开始时间自行渲染时间文本。
        next.date = previous.date
        if next != previous {
            next.date = Date()
            guard WidgetSharedStore.write(next) else {
                if lastSnapshot == nil { AppLog.shared.w("小组件共享权限不可用，请保留扩展及应用组签名") }
                return
            }
            lastSnapshot = next
            needsReload = true
            if identityChanged {
                AppLog.shared.i("组件快照：设备=\(next.devices.count)，使用中=\(next.devices.filter(\.running).count)，上次=\(next.lastDevice)，可展示=\(next.displayedDevice("") != nil)，附近=\(next.nearbyIDs.count)")
            }
        }
        // 合并短时间内的扫描/资料更新，但保证最后一次变更一定会发布。
        if force || identityChanged || (needsReload && Date().timeIntervalSince(lastReload) > 2) {
            reloadTask?.cancel(); reloadTask = nil
            lastReload = Date()
            needsReload = false
            WidgetCenter.shared.reloadAllTimelines()
        } else if needsReload, reloadTask == nil {
            reloadTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.reloadTask = nil
                guard self.needsReload else { return }
                self.needsReload = false; self.lastReload = Date()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    /// 普通导航同步取走，不能留到开阀完成后才返回首页。
    func consumeNavigation() -> WidgetCommandKind? {
        guard let request = command, request.kind.isNavigation else { return nil }
        command = nil
        acceptedSnapshot = nil
        if request.kind == .device || request.kind == .billDetail {
            guard request.owner == AppNotifications.accountKey else { return .home }
            if request.kind == .device { pendingDeviceSN = request.sn }
            else { pendingBillID = request.billID }
        }
        return request.kind
    }

    /// URL 只承接已经渲染的组件按钮；校验随机身份、账号、设备、订单，防止旧按钮操作新单。
    func process(store: AppDataStore, flow: ShowerFlow, scanner: BLEScanner) async -> WidgetCommandKind? {
        guard !handling, !flow.controlBusy, let request = command, !request.kind.isNavigation else { return nil }
        let snapshot = acceptedSnapshot ?? WidgetSharedStore.read()
        acceptedSnapshot = nil
        command = nil
        guard Session.shared.isLoggedIn else { return .home }
        guard request.matches(snapshot), request.owner == AppNotifications.accountKey else {
            flow.toast = "组件状态已更新，请刷新后操作"
            sync(store: store, flow: flow, scanner: scanner, force: true)
            return .home
        }
        let generation = Session.shared.requestGeneration
        let actionID = "\(request.token):\(request.kind.rawValue):\(request.sn)"
        guard !consumed.contains(actionID) else { return .home }
        consumed.insert(actionID)
        handling = true
        operationMessage = request.kind == .stop ? "正在关闭设备…" : request.kind == .start ? "正在获取设备信息…" : "正在刷新…"
        AppLog.shared.i("组件操作开始：\(request.kind.rawValue)，目标 \(request.sn)")
        defer {
            handling = false
            operationMessage = nil
            AppLog.shared.i("组件操作结束：\(request.kind.rawValue)，当前设备 \(flow.activeOrder?.snCode ?? "无")")
            consumed.remove(actionID)
            sync(store: store, flow: flow, scanner: scanner, force: true)
        }
        if request.kind == .refresh || request.kind == .refreshNearby {
            if request.kind == .refreshNearby { scanner.start() }
            await flow.reconcileOnResume()
            await store.reload()
            return request.kind == .refreshNearby ? .nearby : .home
        }
        do {
            guard let info = try await DeviceLookup.load(request.sn) else { flow.toast = "设备不存在"; return .home }
            guard SessionWork.isCurrent(generation) else { return nil }
            await store.putDeviceInfo(info, sn: request.sn)
            if request.kind == .start {
                guard DeviceInfo.inSameRoom(boundKey: Prefs.boundRoom, deviceName: info.deviceName ?? "") else {
                    flow.toast = "设备状态已变化，请刷新"; return .home
                }
                if let record = ActiveOrderStore.find(request.sn) {
                    await flow.resume(record: record)
                    return .start
                }
            }
            let needsBLE = info.needsBluetoothControl || Prefs.isBleDevice(request.sn)
            if needsBLE, scanner.peripheral(forSn: request.sn) == nil {
                operationMessage = "正在搜索设备…"
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
                if !(await flow.handleNotification(DeviceNotificationAction(target: target, stop: true))) {
                    flow.toast = "设备正在处理，请稍后重试"
                }
            } else {
                await flow.open(device: info, peripheral: scanner.peripheral(forSn: request.sn), central: scanner.manager)
            }
        } catch { flow.toast = LoginFeedback.message(error) }
        return request.kind
    }
}
