import Combine
import CoreBluetooth
import Foundation

/// 一次用水的本地记录
struct ActiveOrder {
    let device: DeviceInfo
    let snCode: String
    var orderNo: String
    var consumeDate: String
    let protocolType: String
    let randomNumber: String
    let startedAt: Date
    let preDeductMoney: Double?
    /// 走的是哪条通道。关阀、结算的语义完全不同，必须记住
    let channel: ShowerChannel
    /// 云端表才有：闲置多久自动关（秒）。0 = 服务端没给
    let autoDisConSec: Int

    var elapsedSeconds: Int {
        // ⚠️ 走**持久化**的开阀时间戳：App 被杀/切后台被回收后重新打开，
        // 计时必须接着走，不能从 0 重来（否则用户以为刚开的阀）。
        // 对照 Android `ShowerController.elapsedSeconds`，那边也是纯读 Prefs。
        let ms = Prefs.startedAt(snCode)
        if ms > 0 {
            return max(0, Int((Int64(Date().timeIntervalSince1970 * 1000) - ms) / 1000))
        }
        return max(0, Int(Date().timeIntervalSince(startedAt)))
    }

    /// 自动关停倒计时（秒）。没有这个配置时是 0，界面不显示那一行。
    ///
    /// ⚠️ 读的是持久化的**截止时间戳**，不是「每秒减一」的本地计数 ——
    /// 后者会因为计时器被系统挂起而越走越偏，切后台再回来就对不上了。
    var autoDisConRemain: Int { Prefs.autoDisconRemain(snCode) }
}

enum ShowerChannel {
    /// 云端 `tcpDevice/*`：服务端推给设备（要求 4G）
    case cloud
    /// 蓝牙 `bluetooth/*`：手机当网关
    case ble
}

/// 开阀失败的类型 —— 对照 Android 的 `ShowerErrorKind`。
///
/// 只有 `.serverRejected` 才可能和「欠费」有关，才该引导用户去补扣。
enum ShowerErrorKind {
    case serverRejected
    case other
}

/// 自动关停提示（对照 Android 的 `showAutoCloseDialog`）
struct AutoCloseNotice {
    let deviceName: String
    let elapsedSeconds: Int
    var consumed: Double?
    var loading: Bool
}

/// 开阀 / 关阀 / 结算的**业务编排**。
///
/// ## 两条通道是独立的路
///
/// - `tcpDevice/*`：云端把指令推给设备，要求设备自带 4G
/// - `bluetooth/*`：**手机当网关**，服务端只下发费率包，阀由手机写进设备
///
/// 对蓝牙表调 `tcpDevice` 必然回 `306 设备不在线`。所以入口先按
/// `device.needsBluetoothControl || Prefs.isBleDevice(sn)` 分流，
/// 剩下的按普通表试云端；万一回 306 再**问用户**要不要改用蓝牙
/// （服务端不提供可靠的区分字段，只有站在设备旁的人知道答案）。
@MainActor
final class ShowerFlow: ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var activeOrder: ActiveOrder? {
        didSet {
            guard workScope.isCurrent else { return }
            if oldValue?.snCode != activeOrder?.snCode {
                liveConsumed = nil
                didFireAutoClose = false
                pendingAutoClose = false
            }
            if let order = activeOrder {
                persist(order)
            } else if let old = oldValue {
                clearDeviceState(old.snCode)
            }
        }
    }
    /// 已落盘、但当前**没进入使用页**的订单（App 重启 / 在别处开的阀）。
    ///
    /// 首页那张「使用中的设备」卡片读它 —— 对照 Android：
    /// `activeOrders` 列表才是「有没有在用水」的事实来源，
    /// 内存里的 `isShowering` 只表示「界面是不是停在使用页」。
    @Published private(set) var restoredOrders: [ActiveOrderRecord] = []
    /// 「正在开启」弹窗是否显示
    @Published private(set) var isStarting = false
    private var openingOccupied = false
    /// 开启进度文案（蓝牙表要好几步，不给进度用户会以为卡死）
    @Published private(set) var openingText = ""
    /// 开阀失败文案（非 nil 就弹窗）
    @Published var errorMessage: String? {
        didSet { if errorMessage == nil { errorKind = .other } }
    }
    /// 失败原因分类：服务端明确拒绝 vs 其它（网络/本地校验/结果未知）
    @Published private(set) var errorKind: ShowerErrorKind = .other
    /// 306 之后要问用户「要不要改用蓝牙」
    @Published var bleConfirmDevice: DeviceInfo?
    /// 轻提示
    @Published var toast: String?
    @Published private(set) var isStopping = false
    @Published private(set) var lastConsumeYuan: Double?
    @Published private(set) var settlementRevision = 0
    /// 自动关停弹窗
    @Published var autoClose: AutoCloseNotice?
    /// MQTT 推来的消费金额（元）。nil = 还没收到；使用中没有实时扣费推送。
    ///
    /// 对照 Android `handleMqttMessage` 保留展示更新，**不参与结算**。
    /// 服务端仅在订单结束时推送消费数据，不能据此承诺使用中实时金额。
    @Published private(set) var liveConsumed: Double?

    let ble = BleSession()
    /// MQTT 只是加速器：连不上就安静降级，绝不阻断开阀（Android 同）
    private let mqtt = MqttClient()

    // MARK: - 内部

    private var timer: Timer?
    private let workScope = SessionWorkScope()
    /// 关阀后要断开重连做结算，必须记住当时的 peripheral / central
    private var currentPeripheral: CBPeripheral?
    private var currentCentral: CBCentralManager?
    private var didFireAutoClose = false
    private var pendingAutoClose = false
    private var controlGate = DeviceControlGate()
    private var connectedBleSn: String?
    /// 设备本地状态变化后，之前发出的占用查询不再有写回资格。
    private var deviceRevisions: [String: UInt64] = [:]
    var controlBusy: Bool { controlGate.isBusy }

    private func beginControl() -> UUID? {
        guard workScope.isCurrent else { return nil }
        guard let token = controlGate.begin() else {
            toast = "正在处理设备操作，请稍候"
            return nil
        }
        return token
    }

    init() {
        ble.operationAllowed = { [weak self] in self?.workScope.isCurrent == true }
        restoredOrders = ActiveOrderStore.all()
        if !restoredOrders.isEmpty {
            AppLog.shared.i("启动时发现 \(restoredOrders.count) 条活跃订单：\(restoredOrders.map(\.snCode).joined(separator: ","))")
        }
    }

    // MARK: - 持久化

    /// 落盘当前订单 —— 对照 Android `ShowerController.ensureActiveOrder` 下的那一套。
    ///
    /// ⚠️ 顺序有讲究：**先把计时写进去，再写订单**。反过来的话会出现
    /// 「订单在、计时为 0」的中间态，卡片会显示 00:00 并从零开始走秒。
    private func persist(_ order: ActiveOrder) {
        guard workScope.isCurrent else { return }
        deviceRevisions[order.snCode, default: 0] &+= 1
        if Prefs.startedAt(order.snCode) <= 0 {
            Prefs.setStartedAt(order.snCode, Int64(Date().timeIntervalSince1970 * 1000))
        }
        if order.autoDisConSec > 0, Prefs.autoDisconRemain(order.snCode) <= 0 {
            Prefs.setAutoDisconRemain(order.snCode, seconds: order.autoDisConSec)
        }
        if ActiveOrderStore.find(order.snCode) != nil {
            // ⚠️ 已有记录时**不能整条覆盖**：`orderNo` 是轮询/恢复才补上的，
            // 覆盖成空串之后关阀、结算全都问不出这一单。
            // （对照 Android `ensureActiveOrder`：「有则不动，无则加入」）
            if !order.orderNo.isEmpty {
                ActiveOrderStore.updateOrderNo(snCode: order.snCode, orderNo: order.orderNo)
            }
        } else {
            ActiveOrderStore.upsert(ActiveOrderRecord(
                snCode: order.snCode,
                orderNo: order.orderNo,
                deviceName: order.device.displayName,
                deviceMac: order.device.macAddress ?? order.snCode,
                deviceEmoji: order.device.typeEmoji,
                preDeduct: order.preDeductMoney ?? 0,
                isBluetooth: order.channel == .ble
            ))
        }
        ActiveOrderStore.update { records in
            if let index = records.firstIndex(where: { $0.snCode == order.snCode }) {
                records[index].isBluetooth = order.channel == .ble
            }
        }
        if order.channel == .ble {
            Prefs.markBleDevice(order.snCode)
            BleRecoveryStore.save(BleRecoveryRecord(owner: AppNotifications.accountKey,
                snCode: order.snCode, orderNo: order.orderNo, startedAt: Prefs.startedAt(order.snCode),
                protocolType: order.protocolType, randomNumber: order.randomNumber, consumeDate: order.consumeDate))
        }
        restoredOrders = ActiveOrderStore.all()
        // 使用中通知：同一 identifier 重复 add 只会替换，不会刷屏
        AppNotifications.shared.inUse(device: order.device.displayName, snCode: order.snCode,
                                      orderNo: order.orderNo, startedAt: Prefs.startedAt(order.snCode))
        // 立刻给这一单起监控（Android 在 enterShowerState 里启动 ShowerWatchService）
        startOrderWatch()
    }

    /// 清掉这台设备的本地使用状态
    private func clearDeviceState(_ snCode: String) {
        guard workScope.isCurrent else { return }
        deviceRevisions[snCode, default: 0] &+= 1
        // 不 cancel：此处也可能由监控任务自身调用，它后面仍须完成结算。
        // 先撤销身份，旧任务返回时不能再次处理或移除新的监控任务。
        watchTokens[snCode] = nil
        watchTasks[snCode] = nil
        deviceOwner[snCode] = true
        AppNotifications.shared.clearInUse(snCode: snCode)
        ActiveOrderStore.finish(snCode)
        BleRecoveryStore.remove(snCode: snCode)
        Prefs.setStartedAt(snCode, 0)
        Prefs.clearAutoDiscon(snCode)
        restoredOrders = ActiveOrderStore.all()
    }

    /// 服务端/设备确认这台**已经结束**，而本地还留着记录（自动关停、被外部关掉）。
    ///
    /// 专供「没走 `close()` 的结束路径」使用 —— Android 那边的 `markFinished`。
    /// 不调它的话卡片会一直卡在「使用中」。
    func markFinished(_ snCode: String) {
        guard !snCode.isEmpty else { return }
        clearDeviceState(snCode)
    }

    /// 关阀**没成功**时把刚清掉的本地状态放回去（对照 Android `restoreActiveOrder`）
    func restoreActiveOrder(snCode: String, orderNo: String, startedAtMs: Int64) {
        guard workScope.isCurrent else { return }
        guard !snCode.isEmpty else { return }
        if startedAtMs > 0 { Prefs.setStartedAt(snCode, startedAtMs) }
        if ActiveOrderStore.find(snCode) == nil {
            ActiveOrderStore.upsert(ActiveOrderRecord(
                snCode: snCode,
                orderNo: orderNo,
                deviceName: Prefs.lastDeviceName,
                deviceMac: Prefs.lastDeviceMac,
                deviceEmoji: Prefs.lastDeviceEmoji,
                preDeduct: Prefs.lastDeviceWithholdMoney
            ))
        }
        restoredOrders = ActiveOrderStore.all()
    }

    // MARK: - 开阀

    /// 统一入口：自动决定走云端还是蓝牙。
    ///
    /// ## 允许多单同时存在
    ///
    /// 对照 Android：活跃订单是**列表**，一个账号可以同时开着两台设备
    /// （比如边洗衣服边接水）。`activeOrder` 只表示「使用页当前显示哪一单」，
    /// 其它单继续留在 `ActiveOrderStore` 里，首页照样能看到、能恢复。
    func open(device: DeviceInfo, peripheral: CBPeripheral?, central: CBCentralManager?) async {
        if SessionWork.generation == nil {
            await workScope.run(fallback: ()) { await self.open(device: device, peripheral: peripheral, central: central) }
            return
        }
        guard let token = beginControl() else { return }
        isStarting = true
        errorMessage = nil
        openingOccupied = false
        defer { isStarting = false; openingText = ""; controlGate.finish(token) }
        await performOpen(device: device, peripheral: peripheral, central: central, allowNewOrder: true)
        if workScope.isCurrent, let message = errorMessage {
            AppNotifications.shared.openProblem(device: device.displayName, snCode: device.snCode ?? "",
                                                reason: message, occupied: openingOccupied)
        }
    }

    private func performOpen(device: DeviceInfo, peripheral: CBPeripheral?, central: CBCentralManager?, allowNewOrder: Bool) async {
        guard workScope.isCurrent else { return }

        let sn = device.snCode ?? ""
        // 同一台设备不重复开：已经在用就直接回使用页
        if let current = activeOrder, current.snCode == sn {
            toast = "这台设备正在使用中"
            return
        }
        guard !sn.isEmpty else {
            errorMessage = "设备信息不完整（缺少 snCode）"
            return
        }

        // ① 服务端标记 ② 用户上次确认过这台要蓝牙
        if device.needsBluetoothControl || Prefs.isBleDevice(sn) {
            await openBle(device, peripheral: peripheral, central: central, allowNewOrder: allowNewOrder)
        } else {
            await openCloud(device, allowNewOrder: allowNewOrder)
        }
    }

    /// 用户在「要用蓝牙方式开启吗？」里点了确认
    func confirmBleOpen() async {
        guard workScope.isCurrent else { return }
        guard let device = bleConfirmDevice else { return }
        bleConfirmDevice = nil
        Prefs.markBleDevice(device.snCode ?? "")
        await open(device: device, peripheral: cachedPeripheral(device.snCode ?? ""), central: cachedCentral())
    }

    func dismissBleConfirm() {
        bleConfirmDevice = nil
    }

    func clearError() {
        errorMessage = nil
        errorKind = .other
    }

    // MARK: 云端通道

    private func openCloud(_ device: DeviceInfo, allowNewOrder: Bool) async {
        let sn = device.snCode ?? ""
        openingText = "正在确认设备是否开启，请稍候"

        AppLog.shared.i("=== 云端开阀 \(device.displayName)（sn=\(sn)）===")

        // 云端表订阅 MQTT 订单事件；消费数据仅在订单结束时推送。
        // ⚠️ 连不上不影响开阀，HTTP 才是正确性来源（Android 同）
        liveConsumed = nil
        await mqtt.connect(phone: Session.shared.telephone) { [weak self] payload in
            self?.handleMqtt(payload)
        }

        guard workScope.isCurrent else { return }
        let outcome = await CloudShower.open(snCode: sn, allowNewOrder: allowNewOrder,
                                     expectedOrderNo: allowNewOrder ? nil : ActiveOrderStore.find(sn)?.orderNo)
        guard workScope.isCurrent else { return }
        switch outcome {
        case let .opened(orderNo, consumeDate, autoDisCon, pre):
            rememberDevice(device)
            activeOrder = ActiveOrder(
                device: device,
                snCode: sn,
                orderNo: orderNo,
                consumeDate: consumeDate,
                protocolType: "",
                randomNumber: "",
                startedAt: startDate(sn),
                preDeductMoney: pre,
                channel: .cloud,
                autoDisConSec: autoDisCon
            )
            startTimer()
            AppLog.shared.i("✅ 云端开阀成功 orderNo=\(orderNo) autoDisCon=\(autoDisCon)s")

        case let .resumed(orderNo, pre):
            rememberDevice(device)
            activeOrder = ActiveOrder(
                device: device,
                snCode: sn,
                orderNo: orderNo,
                consumeDate: "",
                protocolType: "",
                randomNumber: "",
                startedAt: startDate(sn),
                preDeductMoney: pre,
                channel: .cloud,
                autoDisConSec: 0
            )
            startTimer()
            toast = "已恢复进行中的订单"

        case .inUseByOthers:
            openingOccupied = true
            mqtt.disconnect()
            errorMessage = "该设备正在被他人使用"

        case .deviceOffline:
            // 只有站在设备旁的人知道这台是不是蓝牙表 —— 必须问
            // （这次的 MQTT 用不上了，改蓝牙后是设备直连）
            mqtt.disconnect()
            bleConfirmDevice = device

        case let .rejected(msg):
            // 服务端明确拒绝：可能是欠费，弹窗里给「立即补扣」入口
            mqtt.disconnect()
            errorKind = .serverRejected
            errorMessage = msg

        case let .failed(msg):
            mqtt.disconnect()
            errorKind = .other
            errorMessage = msg
        }
    }

    // MARK: 蓝牙通道

    private func openBle(_ device: DeviceInfo, peripheral: CBPeripheral?, central: CBCentralManager?, allowNewOrder: Bool) async {
        guard let peripheral, let central else {
            errorMessage = "拿不到设备连接（请重新扫描后再试）"
            return
        }
        currentPeripheral = peripheral
        currentCentral = central

        let sn = device.snCode ?? ""
        AppLog.shared.i("=== 蓝牙开阀 \(device.displayName)（sn=\(sn)）===")

        // 1. 连接
        openingText = "正在连接设备…"
        guard await ble.connect(peripheral: peripheral, using: central) else {
            connectedBleSn = nil
            errorMessage = ble.statusText
            return
        }
        connectedBleSn = sn
        guard workScope.isCurrent else { return }

        // 2. 读状态
        openingText = "正在读取设备状态…"
        guard let st = await ble.query() else {
            ble.disconnect()
            errorMessage = "设备无响应（状态帧读取失败），请靠近设备后重试"
            return
        }

        // 身份核对：状态帧自报的 MAC 必须和要开的那台一致
        guard workScope.isCurrent else { return }
        let expectMac = device.connectMac
        if !st.mac.isEmpty, !expectMac.isEmpty, st.mac.uppercased() != expectMac.uppercased() {
            ble.disconnect()
            errorMessage = "连错设备了（设备报 \(st.mac)）"
            AppLog.shared.e("设备身份不匹配：期望 \(expectMac)，实际 \(st.mac)")
            return
        }

        if st.hasPendingSettle {
            // state=3/6：设备**已关阀但有遗留未结算记录**（上一笔结算失败留下的）。
            //
            // 官方 App 此时走 confirmValveClosed(collect=true) 补结算：0x85 采集 → 上传 →
            // 0x86 写回，清掉记录后设备回到空闲。**不处理的话这台设备永远开不了阀** ——
            // 以前这里直接报「请先用安卓端结清」，那是拿 iOS 的缺功能去要求用户。
            openingText = "正在结清上一笔遗留账单…"
            AppLog.shared.i("蓝牙设备有遗留未结算数据（state=\(st.state)），先补结算")
            let settled = await settlePendingRecords(
                protocolType: st.protocolType,
                randomNumber: st.randomNumber,
                deviceName: device.displayName,
                orderNo: "",
                consumeDate: ""
            )
            ble.disconnect()
            guard workScope.isCurrent else { return }
            guard settled.completed else {
                errorMessage = "设备有未结算记录，自动补结算失败或设备记录未能清除（服务端已记账，设备仍停在 state=\(st.state)），请靠近设备后重试"
                return
            }
            if !allowNewOrder {
                markFinished(sn)
                toast = "设备已关闭，遗留账单已结清"
                return
            }
            // 补结算已清掉设备记录（state 回 0）。断开连接，让用户重新点一次开阀——
            // 重开阀需要一次全新的连接（设备只在新连接里给出可用的会话参数）。
            openingText = ""
            toast = "已结清上一笔遗留账单，请重新点击开阀"
            return
        }
        guard st.isIdle else {
            // 本地有这台设备的活跃订单 → 是「恢复」场景：上一次没关干净 / App 被杀过，
            // 设备其实在为自己出水。别当成「别人在用」报错，直接沿用当前连接进入
            // 使用页——只有保留这条连接，用户才能关阀。
            if ActiveOrderStore.isRunning(sn) {
                AppLog.shared.i("蓝牙设备已在用水（state=\(st.state)），判定为恢复，直接进入使用页")
                let rec = ActiveOrderStore.find(sn)
                let recovery = BleRecoveryStore.read(owner: AppNotifications.accountKey, snCode: sn,
                    orderNo: rec?.orderNo ?? "", startedAt: Prefs.startedAt(sn))
                if Prefs.startedAt(sn) <= 0 {
                    Prefs.setStartedAt(sn, Int64(Date().timeIntervalSince1970 * 1000))
                }
                activeOrder = ActiveOrder(
                    device: device,
                    snCode: sn,
                    orderNo: rec?.orderNo ?? "",
                    consumeDate: recovery?.consumeDate ?? "",
                    protocolType: st.protocolType,
                    randomNumber: st.randomNumber,
                    startedAt: startDate(sn),
                    preDeductMoney: rec?.preDeduct,
                    channel: .ble,
                    autoDisConSec: 0
                )
                startTimer()
                toast = "已恢复进行中的订单"
                return
            }
            ble.disconnect()
            openingOccupied = true
            errorMessage = "设备正在被使用（state=\(st.state)）"
            return
        }

        guard allowNewOrder else {
            ble.disconnect()
            markFinished(sn)
            toast = "设备已关闭"
            return
        }

        // 3. 向云端申请费率包
        openingText = "正在向云端申请费率…"
        guard let deviceId = device.deviceId.map(String.init) else {
            ble.disconnect()
            errorMessage = "设备缺少 deviceId"
            return
        }
        let xfModel = "0"
        let macType = BleSign.macType(type: st.devType, a1: st.a1)

        guard let signature = BleSign.signRateOrder(
            loginCode: Session.shared.loginCode,
            telephone: Session.shared.telephone,
            deviceId: deviceId,
            xfModel: xfModel,
            randomNumber: st.randomNumber
        ) else {
            ble.disconnect()
            errorMessage = "签名计算失败（登录态可能失效）"
            return
        }

        let rateData: Data
        do {
            rateData = try await ApiClient.post("/order/downRate/bluetooth/rateOrder", form:
                BleRequestFields.rate(device: device, deviceId: deviceId, mac: expectMac,
                                      macType: macType, state: st, xfModel: xfModel, signature: signature), tag: "rateOrder")
        } catch {
            ble.disconnect()
            errorMessage = "申请费率失败：\(LoginFeedback.message(error))"
            return
        }

        let rateResp: APIResponse<BluetoothRateOrderData>
        guard workScope.isCurrent else { return }
        do {
            rateResp = try ApiClient.decode(BluetoothRateOrderData.self, from: rateData, path: "bluetoothRateOrder")
        } catch {
            ble.disconnect()
            errorMessage = "费率响应异常，请重试"
            return
        }

        guard let downHex = rateResp.data?.downData,
              let downBytes = BleFrame.fromHex(downHex),
              !downBytes.isEmpty
        else {
            ble.disconnect()
            errorMessage = rateResp.displayMessage ?? "云端没返回有效费率包"
            return
        }
        AppLog.shared.i("云端下发费率包 \(downBytes.count)B")

        // 4. 写入设备（真正开阀）
        openingText = "正在写入费率并开阀…"
        guard await ble.writeRate(downBytes) else {
            ble.disconnect()
            errorMessage = "未能确认设备已开启，请确认水流状态后决定是否重试"
            return
        }

        // 5. 记账
        guard workScope.isCurrent else { return }
        rememberDevice(device)
        activeOrder = ActiveOrder(
            device: device,
            snCode: sn,
            orderNo: rateResp.data?.orderNo ?? "",
            consumeDate: rateResp.data?.consumeDate ?? "",
            protocolType: st.protocolType,
            randomNumber: st.randomNumber,
            startedAt: startDate(sn),
            preDeductMoney: rateResp.data?.preDeductYuan,
            channel: .ble,
            autoDisConSec: rateResp.data?.autoDisConTime ?? 0
        )
        startTimer()
        AppLog.shared.i("✅ 蓝牙开阀成功 orderNo=\(rateResp.data?.orderNo ?? "")")
    }

    // MARK: - 关阀

    /// 关阀。
    ///
    /// ## 核心语义（对照 Android 的 `stopBleShower` / `stopShower`）
    ///
    /// **水确认关掉就立刻退出使用页**，结算在后台异步做，结果用 toast 告诉用户。
    ///
    /// 以前的实现把「关阀 + 重连 + 采集 + 上传」串成一整条 await 链，
    /// 任何一步失败或卡住，界面就停在「正在关闭…」——而用户看到的阀门其实早就关了。
    /// 这是真机上「一直卡住正在关闭」的直接原因，必须这样拆开。
    ///
    /// 只有**水可能还在流**时才留在页面（让用户能重试）。
    func close() async {
        if SessionWork.generation == nil {
            await workScope.run(fallback: ()) { await self.close() }
            return
        }
        guard let order = activeOrder, let token = beginControl() else { return }
        defer { controlGate.finish(token) }
        await performClose(order)
    }

    private func performClose(_ order: ActiveOrder) async {
        guard workScope.isCurrent else { return }
        isStopping = true
        defer { isStopping = false }
        let elapsed = order.elapsedSeconds
        let automatic = pendingAutoClose
        pendingAutoClose = false
        stopTimer()

        AppLog.shared.i("=== 开始关阀 \(order.snCode)，已用 \(order.elapsedSeconds)s，通道=\(order.channel) ===")

        switch order.channel {
        case .cloud:
            await closeCloud(order, elapsed: elapsed, automatic: automatic)
        case .ble:
            await closeBle(order, elapsed: elapsed, automatic: automatic)
        }

    }

    private func closeCloud(_ order: ActiveOrder, elapsed: Int, automatic: Bool) async {
        // 对照 Android 停止流程断开 MQTT；最终金额以结算查询为准。
        defer { mqtt.disconnect() }
        // ⚠️ orderNo 必须在关阀**之前**敲定：关阀成功后订单就没了，
        // `queryUsing` 再也问不出来，后面的结算只能退化成按时间窗猜账单。
        let resolved = await CloudShower.resolveOrderNo(snCode: order.snCode)
        guard workScope.isCurrent else { return }
        guard order.orderNo.isEmpty || resolved.isEmpty || resolved == order.orderNo else {
            toast = "设备订单已变化，请刷新设备状态后操作"
            startTimer()
            return
        }
        let orderNo = resolved.isEmpty ? order.orderNo : resolved
        var settledOrder = order
        settledOrder.orderNo = orderNo
        let r = await CloudShower.close(snCode: order.snCode, orderNo: orderNo)
        guard workScope.isCurrent else { return }
        switch r {
        case .closed:
            // 水已关 → 立刻退出使用页
            activeOrder = nil
            toast = "热水器已关闭"
            Task { await workScope.run(fallback: ()) { await self.settleCloud(settledOrder, elapsed: elapsed, automatic: automatic) } }
        case let .unconfirmed(msg):
            // 没有证据 = 水可能还在流。留在页面让用户重试
            AppNotifications.shared.closeProblem(device: order.device.displayName, snCode: order.snCode)
            toast = "没能确认设备已关闭，请检查网络后重试"
            startTimer()
        case let .failed(msg):
            AppNotifications.shared.closeProblem(device: order.device.displayName, snCode: order.snCode, reason: msg)
            toast = msg
            startTimer()
        }
    }

    private func closeBle(_ order: ActiveOrder, elapsed: Int, automatic: Bool) async {
        // 当前使用页可能是 A，但最近一次连接尝试指向 B。写关阀前必须核对目标。
        if connectedBleSn != order.snCode || ble.phase != .ready {
            guard let peripheral = cachedPeripheral(order.snCode), let central = cachedCentral(),
                  await ble.connect(peripheral: peripheral, using: central) else {
                toast = "请靠近目标设备，扫描后重试关闭"
                startTimer()
                return
            }
            currentPeripheral = peripheral
            currentCentral = central
            connectedBleSn = order.snCode
        }
        guard workScope.isCurrent else { return }
        guard let state = await ble.query(),
              !state.mac.isEmpty,
              state.mac.uppercased() == order.device.connectMac.uppercased() else {
            toast = "无法确认目标设备，请重新扫描后重试"
            startTimer()
            return
        }
        guard workScope.isCurrent else { return }
        let r = await ble.closeValve()
        guard workScope.isCurrent else { return }

        guard r.waterStopped else {
            // ⚠️ 水可能还在流 —— 留在使用页，让他能重试
            AppNotifications.shared.closeProblem(device: order.device.displayName, snCode: order.snCode,
                reason: "设备没有响应关闭指令，请靠近设备后重试")
            toast = "设备没有响应关闭指令，请靠近设备后重试"
            AppLog.shared.w("蓝牙关阀未确认，保留使用页以便重试")
            startTimer()
            return
        }

        // 水已关：立刻退出使用页，剩下的结算在后台做
        activeOrder = nil
        didFireAutoClose = false
        toast = "热水器已关闭"
        // 界面已退出使用页，但控制锁继续覆盖重连、采集、上传、写回。
        // 新设备不能在这段时间复用同一个 BleSession。
        await settleBle(order, elapsed: elapsed, autoClosed: automatic)
    }

    // MARK: - 结算

    /// 蓝牙结算（关阀之后调用，此时**已经不在使用页**）
    ///
    /// 六步里第 ② 步「断开重连」是关键：Android 端 2026-09-30 用同一笔订单实测对比过，
    /// 同一连接里「关阀后立刻采集」会被服务端判 226「加密校验失败」、账单停在 0.0；
    /// 断开重连后再采集才被接受。原因是重连后设备才给出新的 `randomNumber`，
    /// 而上传签名用的正是它。
    private func settleBle(_ order: ActiveOrder, elapsed: Int, autoClosed: Bool = false) async {
        guard workScope.isCurrent else { return }

        defer {
            ble.disconnect()
            connectedBleSn = nil
            currentPeripheral = nil
            currentCentral = nil
        }

        guard let p = currentPeripheral, let central = currentCentral else {
            finishWithAmount(nil, autoClosed: autoClosed, deviceName: order.device.displayName, snCode: order.snCode, elapsed: elapsed)
            return
        }

        // ② 断开 → 重连
        ble.disconnect()
        // 对齐 Android：无固定等待。BleSession 等旧连接终止事件后即可重连。
        guard workScope.isCurrent else { return }

        var reconnected = await ble.connect(peripheral: p, using: central)
        if !reconnected {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard workScope.isCurrent else { return }
            reconnected = await ble.connect(peripheral: p, using: central)
        }
        guard reconnected else {
            AppLog.shared.w("结算重连失败")
            finishWithAmount(nil, autoClosed: autoClosed, deviceName: order.device.displayName, snCode: order.snCode, elapsed: elapsed)
            return
        }

        // ③ 重新读状态 —— 要拿**新的** randomNumber / protocolType
        var st: DeviceState?
        for attempt in 1 ... 3 {
            guard workScope.isCurrent else { return }
            st = await ble.query(timeout: 4)
            if st != nil { break }
            AppLog.shared.w("第 \(attempt) 次 0x23 无应答，600ms 后重试")
            if attempt < 3 { try? await Task.sleep(nanoseconds: 600_000_000) }
        }

        let protocolType: String
        let randomNumber: String
        if let s = st {
            AppLog.shared.i("关阀重连后状态：\(s.describe)")
            protocolType = s.protocolType
            randomNumber = s.randomNumber
        } else {
            // 兜底：randomNumber 只在申请费率时更新，关阀不会改它
            AppLog.shared.w("0x23 三次无应答，改用开阀时的 protocolType/randomNumber 兜底")
            protocolType = order.protocolType
            randomNumber = order.randomNumber
        }

        // ④~⑥ 采集 → 上传 → 写回（与「补结算」同一条路，见 settlePendingRecords）
        let result = await settlePendingRecords(
            protocolType: protocolType,
            randomNumber: randomNumber,
            deviceName: order.device.displayName,
            orderNo: order.orderNo,
            consumeDate: order.consumeDate
        )
        guard workScope.isCurrent else { return }
        if let amount = result.amount {
            Prefs.recordConsume(order.snCode, amount: amount)
        }
        finishWithAmount(result.amount, autoClosed: autoClosed, deviceName: order.device.displayName, snCode: order.snCode, elapsed: elapsed)
        if !result.completed {
            // ⚠️ 蓝牙通道没有服务端兜底：不上报的话这一单会一直挂在预扣状态
            await reportFail(order)
        }
    }

    /// 蓝牙「采集 → 上传 → 写回」——逐条对照 Android 的
    /// `BleShowerController.settlePending`。
    ///
    /// 两个调用点共用：
    /// 1. 关阀后的结算
    /// 2. 开阀前发现设备 `state=3/6`（有遗留未结算记录）的**补结算**
    ///
    /// @return `completed` = 上传被服务端接受；`amount` = 本次消费（元，nil = 没拿到）
    @discardableResult
    private func settlePendingRecords(
        protocolType: String,
        randomNumber: String,
        deviceName: String,
        orderNo: String,
        consumeDate: String
    ) async -> (completed: Bool, amount: Double?) {
        guard workScope.isCurrent else { return (false, nil) }
        // ① 采集
        guard let payload = await ble.collect() else {
            AppLog.shared.w("结算：0x85 采集失败")
            return (false, nil)
        }
        // ⚠️ 设备回的不是账单就不能上传。官方 SDK 的消费体是 42 字节起步，
        // 首字节 0x80 是成功标记。拿到错误应答或半截载荷还硬上传的话，
        // 服务端会把它当一条消费记录处理——轻则报错，重则**记错账**。
        guard payload.count >= 42, payload.first == 0x80 else {
            let firstHex = payload.first.map { String(format: "0x%02X", $0) } ?? "空"
            AppLog.shared.w("结算：消费数据无效（\(payload.count)B，首字节 \(firstHex)），放弃上传")
            return (false, nil)
        }

        // ② 上传（xfData 必须**小写**：服务端对大小写敏感，签名用小写、上传字段也得小写）
        guard workScope.isCurrent else { return (false, nil) }
        let xfData = BleFrame.toHex(payload).lowercased()
        guard let sig = BleSign.signUpload(
            loginCode: Session.shared.loginCode,
            telephone: Session.shared.telephone,
            xfData: xfData
        ) else {
            AppLog.shared.w("结算：签名失败")
            return (false, nil)
        }

        do {
            let data = try await ApiClient.post("/order/upload/bluetooth/data", form:
                BleRequestFields.upload(protocolType: protocolType, randomNumber: randomNumber,
                                        xfData: xfData, signature: sig), tag: "upload")
            // ⚠️ 必须用 decodeShell：206/209 是「已受理」的**成功码**，
            // 走 decode 会被当成异常，结算被误判失败、订单被上报作废。
            let resp = try ApiClient.decodeShell(BluetoothUploadData.self, from: data, path: "bluetoothUpload")
            let code = resp.errorCode ?? -1
            let accepted = resp.success || code == 206 || code == 209
            guard accepted, let body = resp.data else {
                if code == 170 {
                    AppLog.shared.e("结算上传被拒（170）：签名与上传字段不一致，请带日志反馈")
                }
                // data 为空但外壳成功：多半是字段解码整体失败，把原文打出来
                if resp.success {
                    AppLog.shared.w("结算上传成功但 data 解析为空，原始响应："
                                    + String((String(data: data, encoding: .utf8) ?? "").prefix(500)))
                }
                AppLog.shared.w("结算上传失败（errorCode=\(code)）：\(resp.displayMessage ?? "")")
                return (false, nil)
            }

            let yuan = body.upMoneyYuan
            // 容错解码留下的问题字段：正常应为空，非空说明服务端某字段类型不符合预期
            if !body.decodeIssues.isEmpty {
                AppLog.shared.w("结算上传响应有字段解码异常（已按 nil 处理，不影响 clData）："
                                + body.decodeIssues.joined(separator: "；"))
            }
            guard workScope.isCurrent else { return (false, nil) }

            // ③ 写回设备（清掉离线记录）。
            //
            // 服务端记账成功 ≠ 设备记录已清。写回失败时设备会**一直停在 state=3/6**，
            // 于是每次点开阀都会重新走一遍补结算、再提示"已结清…请重新点击"，
            // 补结算看起来次次成功，热水却始终开不了。
            // 因此这里必须回读状态确认设备真的回到空闲，才能对外报"已结清"。
            var cleared = false

            // ⚠️ 兜底：先从原始 JSON 里直接取 clData，再退到模型字段。
            //
            // 实测（2026-10-27，projectId=859，设备 C47F0E6B1704）：同一个响应里
            // `orderNo` / `consumeMoney` / `consumeDate` 都能解出来，唯独 `clData`
            // 恒为 nil，且 `decodeIssues` 为空——模型解码这条路不可靠。
            // 而 `clData` 是清除设备离线记录的**唯一**数据源，拿不到就等于永远开不了阀，
            // 所以这里直接从原始 JSON 兜一层，不把成败押在 `Decodable` 上。
            var effectiveClData = body.clData
            if effectiveClData?.isEmpty != false {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = obj["data"] as? [String: Any],
                   let raw = d["clData"] as? String, !raw.isEmpty {
                    effectiveClData = raw
                    AppLog.shared.w("结算：模型字段 clData 为空，已从原始 JSON 兜底取到（\(raw.count) 字符）")
                }
            }

            if let rawCl = effectiveClData, !rawCl.isEmpty {
                let plain = KlcxkjCrypto.decryptByAes(rawCl)
                if let plain {
                    let hexPart = plain.contains("-")
                        ? String(plain.split(separator: "-", maxSplits: 1).last ?? "")
                        : plain
                    if let bytes = BleFrame.fromHex(hexPart), !bytes.isEmpty {
                        let ok = await ble.writeBack(bytes)
                        AppLog.shared.i(ok ? "0x86 写回成功（\(bytes.count)B），设备记录已清"
                                        : "0x86 写回失败（服务端已记账），\(bytes.count)B")
                        cleared = ok
                    } else {
                        AppLog.shared.w("结算：clData 解密后不是有效 hex（明文=\(plain)），跳过写回")
                    }
                } else {
                    AppLog.shared.w("结算：clData 解密失败（原始密文长度=\(rawCl.count)）。"
                                    + "明文为空说明 AES 参数不对或 base64 解析中断")
                }
            } else {
                AppLog.shared.w("结算：服务端未返回 clData，设备记录无法清除"
                                + "（orderNo=\(body.orderNo ?? "-")，原始响应："
                                + String((String(data: data, encoding: .utf8) ?? "").prefix(500)) + "）")
            }

            // ④ 回读设备状态：state 回到 0 才算真正清干净
            if let st = await ble.query() {
                AppLog.shared.i("结算后回读：state=\(st.state)")
                if st.isIdle { cleared = true }
            }

            AppLog.shared.i("结算上传成功：设备=\(deviceName) orderNo=\(orderNo) upMoney=\(body.upMoney?.value ?? body.consumeMoney?.value ?? -1)")
            _ = consumeDate
            // cleared=false 时上层要按"未清干净"处理，不能再提示用户重新点击
            return (cleared, yuan)
        } catch {
            AppLog.shared.w("上传结算失败：\(error.localizedDescription)")
            return (false, nil)
        }
    }

    private func settleCloud(_ order: ActiveOrder, elapsed: Int, automatic: Bool = false) async {
        guard workScope.isCurrent else { return }
        let accountKey = AppNotifications.accountKey
        // 与 Android 的 `SettlementEngine.settleAmount` 完全同一条路：
        // 直答接口 → 零确认 → 账单列表回退 → 登记待对账
        let yuan = await SettlementEngine.settleAmount(
            orderNo: order.orderNo,
            startTimeMs: Int64(order.startedAt.timeIntervalSince1970 * 1000),
            snCode: order.snCode,
            deviceName: order.device.displayName
        )
        guard workScope.isCurrent, AppNotifications.accountKey == accountKey else { return }
        finishWithAmount(yuan, autoClosed: automatic, deviceName: order.device.displayName, snCode: order.snCode, elapsed: elapsed)
    }

    /// 处理 MQTT 推送 —— 逐条对照 Android `handleMqttMessage`。
    ///
    /// 两个用途：
    /// 1. **补 orderNo**：开阀时服务端可能还没生成，推送里带的就是真的那一单
    /// 2. 消费金额到达时更新展示；按 Android 文档，订单结束前没有中间扣费推送。
    ///
    /// ⚠️ 只补「还没有 orderNo」的情况：已有值就信任已有值，
    /// 否则同一单可能被反复改写（Android 那里也踩过 orderNo 被写成 snCode 的坑）。
    private func handleMqtt(_ payload: String) {
        guard workScope.isCurrent else { return }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let orderNo = obj["orderNo"] as? String, !orderNo.isEmpty,
           let order = activeOrder, order.orderNo.isEmpty {
            activeOrder?.orderNo = orderNo
            ActiveOrderStore.updateOrderNo(snCode: order.snCode, orderNo: orderNo)
            AppLog.shared.i("MQTT 补到 orderNo=\(orderNo)")
        }

        // ⚠️ 金额字段有三套写法（数字/字符串都出现过），统一走 AnyNumber 那套宽松解析
        if let raw = obj["consumeMoney"], let money = Self.anyNumber(raw) {
            liveConsumed = money
            AppLog.shared.i("MQTT 消费金额推送：¥\(MoneyFormat.format(money))")
        }
    }

    private static func anyNumber(_ raw: Any) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    /// 保留 Android 的「预扣 − 已收到消费金额」展示公式；不代表有使用中推送。
    func remainingText(_ order: ActiveOrder) -> String {
        let pre = order.preDeductMoney ?? 0
        if let consumed = liveConsumed {
            return String(format: "%.2f", max(0, pre - consumed))
        }
        return pre > 0 ? String(format: "%.2f", pre) : "0.00"
    }

    /// 结算完成：记金额、弹提示（或自动关停弹窗）
    private func finishWithAmount(_ yuan: Double?, autoClosed: Bool, deviceName: String, snCode: String, elapsed: Int) {
        guard workScope.isCurrent else { return }
        // 关阀时长已确定，不把等待结算的时间计入后续补发通知。
        if var pending = PendingSettlementStore.all().first(where: { $0.snCode == snCode }) {
            pending.elapsedSec = max(0, elapsed)
            PendingSettlementStore.record(pending)
        }
        AppNotifications.shared.finished(device: deviceName, snCode: snCode,
            elapsed: elapsed,
            amount: yuan, automatic: autoClosed)
        lastConsumeYuan = yuan
        settlementRevision += 1
        if let yuan, yuan > 0 { Prefs.lastConsumeYuan = yuan }

        if autoClosed {
            // 自动关停：弹窗说清楚「为什么关了 + 花了多少」
            autoClose = AutoCloseNotice(
                deviceName: deviceName,
                elapsedSeconds: elapsed,
                consumed: yuan,
                loading: false
            )
            return
        }

        if let yuan {
            toast = yuan > 0
                ? "已停止，本次消费 \(MoneyFormat.withSymbol(yuan))"
                : "热水器已关闭，本次无消费"
        } else {
            // nil = 还不知道，不是没花钱
            toast = "已停止，消费金额稍后可在账单中查看"
        }
    }

    /// 结算失败时向服务端上报作废（蓝牙通道必须做：没有服务端兜底）
    private func reportFail(_ order: ActiveOrder) async {
        guard workScope.isCurrent else { return }
        guard !order.consumeDate.isEmpty else { return }
        guard let sig = BleSign.signFail(
            loginCode: Session.shared.loginCode,
            telephone: Session.shared.telephone,
            consumeDate: order.consumeDate
        ) else { return }
        do {
            _ = try await ApiClient.post("/order/upload/bluetooth/fail", form: [
                "consumeDate": order.consumeDate,
                "signature": sig,
            ], tag: "fail")
            AppLog.shared.i("已上报失败订单（作废）")
        } catch {
            AppLog.shared.w("上报失败订单也失败了：\(error.localizedDescription)")
        }
    }

    // MARK: - 计时 / 自动关停

    private func startTimer() {
        guard workScope.isCurrent else { return }
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard workScope.isCurrent else { reset(); return }
        refreshInUseNotifications()
        guard let order = activeOrder else { return }
        objectWillChange.send()

        // 自动关停：对照 Android，**倒计时是持久化的截止时间戳**，
        // 所以切后台、锁屏都不会把它推迟。
        //
        // ⚠️ Android 由前台服务 `ShowerWatchService` 执行关阀，iOS 没那种常驻能力，
        // 只能在前台（或回到前台那一刻）发现到点并主动关阀——这是系统限制，
        // 不是实现偷懒。回到前台的对齐见 `reconcileOnResume()`。
        guard order.autoDisConSec > 0, !didFireAutoClose, !controlGate.isBusy else { return }
        if Prefs.autoDisconRemain(order.snCode) <= 0 {
            didFireAutoClose = true
            pendingAutoClose = true
            AppLog.shared.i("到达自动关停时间（\(order.autoDisConSec)s），主动关阀")
            Task { await close() }
        }
    }

    /// 普通通知仅提示已确认的使用状态，不显示计时或提供关阀按钮。
    func refreshInUseNotifications() {
        guard workScope.isCurrent else { return }
        for record in ActiveOrderStore.all() {
            let start = Prefs.startedAt(record.snCode)
            guard start > 0 else { continue }
            AppNotifications.shared.inUse(device: record.deviceName, snCode: record.snCode,
                orderNo: record.orderNo, startedAt: start)
        }
    }

    /// 回到前台时对齐一次用水状态 —— 对照 Android `MainViewModel.reconcileShowerOnResume`。
    ///
    /// 一个进程内的计时器靠不住：系统会把 App 挂起，`Timer` 不走，
    /// 而**服务端/设备那边时间是照走的**。回到前台必须重新对一次：
    ///
    /// - 订单还在 → 把界面的秒数和倒计时拉正
    /// - 订单没了（在别处被关）→ 收尾退出使用页
    func reconcileOnResume() async {
        if SessionWork.generation == nil {
            await workScope.run(fallback: ()) { await self.reconcileOnResume() }
            return
        }
        guard workScope.isCurrent else { return }
        guard !controlGate.isBusy else { return }
        guard let order = activeOrder else {
            restoredOrders = ActiveOrderStore.all()
            return
        }
        objectWillChange.send()
        if !ActiveOrderStore.isRunning(order.snCode) {
            // 本地记录也没了（被其它路径清过）——直接收尾，不要挂着空柱
            AppLog.shared.i("回前台对齐：\(order.snCode) 本地已无活跃订单，退出使用页")
            activeOrder = nil
            stopTimer()
            return
        }
        // 云端表：问一次服务端还在不在用水（蓝牙表不能这么问，得连着）
        if order.channel == .cloud {
            let running = await CloudShower.orderRunning(snCode: order.snCode)
            guard workScope.isCurrent else { return }
            guard !controlGate.isBusy, activeOrder?.snCode == order.snCode else { return }
            if running == false {
                AppLog.shared.i("回前台对齐：服务端已无订单，退出使用页")
                let elapsed = order.elapsedSeconds
                activeOrder = nil
                stopTimer()
                toast = "设备已关闭"
                Task { await workScope.run(fallback: ()) { await self.settleCloud(order, elapsed: elapsed, automatic: true) } }
            }
        }
    }

    /// 复核待对账记录 —— 对照 Android `SettlementReconciler` 的周期对账。
    ///
    /// 拉一次账单列表，能匹配上的就把金额补上并弹提示，匹配不上的继续留着。
    @discardableResult
    func reconcileSettlements() async -> [SettlementUpdate] {
        if SessionWork.generation == nil {
            return await workScope.run(fallback: []) { await self.reconcileSettlements() }
        }
        guard workScope.isCurrent else { return [] }
        let pending = PendingSettlementStore.all()
        guard !pending.isEmpty else { return [] }

        guard let bills = await BillService.loadHistoryOrNil() else {
            AppLog.shared.w("待对账复核：账单拉取失败，保留 \(pending.count) 条")
            return []
        }
        guard workScope.isCurrent else { return [] }
        return reconcileLoadedBills(bills)
    }

    /// 账单刷新成功后复用结果，不为补通知重复请求三个月账单。
    @discardableResult
    func reconcileLoadedBills(_ bills: [BillDTO], pending: [PendingSettlement]? = nil) -> [SettlementUpdate] {
        guard workScope.isCurrent else { return [] }
        let pending = pending ?? PendingSettlementStore.all()
        let result = SettlementReconciler.reconcile(pending: pending, bills: bills)
        PendingSettlementStore.save(result.remaining)

        for update in result.updates {
            if let item = pending.first(where: { $0.snCode == update.snCode }) {
                AppNotifications.shared.correctSettlement(item, amount: update.amount)
            }
            Prefs.recordConsume(update.snCode, amount: update.amount)
            Prefs.lastConsumeYuan = update.amount
            AppLog.shared.i("待对账补齐：\(update.snCode) ¥\(MoneyFormat.format(update.amount))")
        }
        if !result.updates.isEmpty {
            toast = "上笔用水已结算：\(MoneyFormat.withSymbol(result.updates.reduce(0) { $0 + $1.amount }))"
            settlementRevision += 1
        }
        return result.updates
    }

    /// 关掉自动关停弹窗
    func dismissAutoClose() {
        autoClose = nil
    }

    // MARK: - 其它

    private func rememberDevice(_ device: DeviceInfo) {
        guard workScope.isCurrent else { return }
        Prefs.lastDeviceName = device.displayName
        Prefs.lastDeviceMac = device.macAddress ?? device.snCode ?? ""
        Prefs.lastDeviceSnCode = device.snCode ?? ""
        Prefs.lastDeviceEmoji = device.typeEmoji
        // 下面三个是「恢复订单 / 卡片副标题 / 预扣金额」用的，
        // 少了它们，App 重启后恢复出来的卡片会显示空白名和 ¥0.00
        Prefs.lastDeviceRawName = device.deviceName ?? ""
        Prefs.lastDeviceTypeName = device.typeLabel
        Prefs.lastDeviceWithholdMoney = device.withholdYuan ?? 0
    }

    /// 从首页「使用中的设备」卡片恢复订单 —— 对照 Android `restoreShowerScreen`。
    ///
    /// ## 为什么恢复时仍要查询设备
    ///
    /// 恢复**不是**纯本地操作：内存里的连接对象早就没了，必须先拿到设备台账，
    /// 再让通道自己确认（云端查 `queryUsing`、蓝牙读状态帧）。
    /// 两边都会回「已有订单、是你的」→ 直接沿用，**不会重新开阀、不会重复扣预扣**。
    func resume(record: ActiveOrderRecord) async {
        if SessionWork.generation == nil {
            await workScope.run(fallback: ()) { await self.resume(record: record) }
            return
        }
        guard let token = beginControl() else { return }
        defer { controlGate.finish(token) }
        await restoreExisting(record: record)
    }

    private func restoreExisting(record: ActiveOrderRecord) async {
        guard workScope.isCurrent else { return }
        // 已经在显示这一单 → 什么都不用做
        if activeOrder?.snCode == record.snCode { return }
        let sn = record.snCode
        guard !sn.isEmpty, ActiveOrderStore.find(sn) == record else { return }
        isStarting = true
        defer { isStarting = false; openingText = "" }

        // 台账：优先内存缓存，其次服务端
        let info: DeviceInfo
        if let cached = cachedDevice(sn) {
            info = cached
        } else {
            do {
                guard let d = try await DeviceLookup.load(sn) else {
                    flowToast("获取设备信息失败，稍后重试")
                    return
                }
                info = d
            } catch {
                flowToast("获取设备信息失败：\(LoginFeedback.message(error))")
                return
            }
        }

        // ⚠️ 必须真的扫到这台设备才能走蓝牙：CoreBluetooth 只认 `CBPeripheral`，
        // 没扫到就无法连接。这里不清掉记录，只提示去附近设备里选。
        if record.isBluetooth == true { Prefs.markBleDevice(sn) }
        if info.needsBluetoothControl || Prefs.isBleDevice(sn) {
            if let p = cachedPeripheral(sn), let central = cachedCentral() {
                await performOpen(device: info, peripheral: p, central: central, allowNewOrder: false)
            } else {
                flowToast("这台是蓝牙表，请从「附近设备」里选它（需要先扫描到）")
            }
            return
        }
        await performOpen(device: info, peripheral: nil, central: nil, allowNewOrder: false)
    }

    /// 通知与 Android 的 doFinish(snCode) 一样，操作目标不依赖当前显示的使用页。
    /// 返回 false 只表示控制链忙，调用方保留动作，空闲后再处理。
    func handleNotification(_ action: DeviceNotificationAction) async -> Bool {
        if SessionWork.generation == nil {
            return await workScope.run(fallback: true) { await self.handleNotification(action) }
        }
        guard workScope.isCurrent else { return true }
        guard !controlGate.isBusy else { return false }
        let target = action.target
        guard workScope.isCurrent,
              target.matches(accountKey: AppNotifications.accountKey,
                             record: ActiveOrderStore.find(target.snCode),
                             startedAt: Prefs.startedAt(target.snCode)),
              let record = ActiveOrderStore.find(target.snCode) else {
            toast = "通知对应的订单已失效，请在首页确认设备状态"
            return true
        }
        guard let token = controlGate.begin() else { return false }
        defer { controlGate.finish(token) }

        if !action.stop {
            await restoreExisting(record: record)
            return true
        }
        // 旧记录通道未知时先查台账/恢复，不能把“没有蓝牙标记”当成已知云端表。
        if activeOrder?.snCode == target.snCode || record.isBluetooth != false || Prefs.isBleDevice(target.snCode) {
            await restoreExisting(record: record)
            // 可能未扫描到或设备已空闲，绝不能回退到关闭当前显示的其它设备。
            if let order = activeOrder, order.snCode == target.snCode,
               target.matches(accountKey: AppNotifications.accountKey,
                              record: ActiveOrderStore.find(target.snCode),
                              startedAt: Prefs.startedAt(target.snCode)) {
                if order.channel == .cloud, !(await cloudNotificationStillMatches(target)) { return true }
                await performClose(order)
            }
            return true
        }

        // 非当前的云端订单无需切换使用页，也不经过申请费率/开阀路径。
        isStopping = true
        defer { isStopping = false }
        guard await cloudNotificationStillMatches(target) else { return true }
        let elapsed = max(0, Int((Int64(Date().timeIntervalSince1970 * 1000) - target.startedAt) / 1000))
        let orderNo = target.orderNo.isEmpty ? record.orderNo : target.orderNo
        guard target.matches(accountKey: AppNotifications.accountKey,
                             record: ActiveOrderStore.find(target.snCode),
                             startedAt: Prefs.startedAt(target.snCode)) else { return true }
        let outcome = await CloudShower.close(snCode: target.snCode, orderNo: orderNo)
        guard workScope.isCurrent else { return true }
        switch outcome {
        case .closed:
            markFinished(target.snCode)
            toast = "热水器已关闭"
            let accountKey = AppNotifications.accountKey
            Task {
                await workScope.run(fallback: ()) { [self] in
                    let amount = await SettlementEngine.settleAmount(orderNo: orderNo,
                        startTimeMs: target.startedAt, snCode: target.snCode, deviceName: record.deviceName)
                    guard workScope.isCurrent, AppNotifications.accountKey == accountKey else { return }
                    finishWithAmount(amount, autoClosed: false, deviceName: record.deviceName,
                                     snCode: target.snCode, elapsed: elapsed)
                }
            }
        case let .failed(message):
            toast = message
            AppNotifications.shared.closeProblem(device: record.deviceName, snCode: target.snCode, reason: message)
        case .unconfirmed:
            toast = "没能确认设备已关闭，请检查网络后重试"
            AppNotifications.shared.closeProblem(device: record.deviceName, snCode: target.snCode)
        }
        return true
    }

    private func cloudNotificationStillMatches(_ target: DeviceNotificationTarget) async -> Bool {
        guard let response = try? await CloudShower.queryUsing(snCode: target.snCode),
              response.success || response.errorCode == 307,
              let record = ActiveOrderStore.find(target.snCode),
              target.matches(accountKey: AppNotifications.accountKey, record: record,
                             startedAt: Prefs.startedAt(target.snCode)),
              target.matchesServerOrder(record: record, orderNo: response.data?.orderNo,
                                        isOwner: response.data?.isOwner) else {
            toast = "无法确认通知对应的原订单，请在首页确认后再停止"
            return false
        }
        return true
    }

    // MARK: - 订单监控（对照 Android ShowerWatchService.watch）

    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var watchTokens: [String: UUID] = [:]

    /// 给每条活跃订单起一个监控任务。
    ///
    /// ## 它解决什么问题
    ///
    /// 订单可能**不是在这个 App 里结束**的：设备到点自己关了、服务端超时关了、
    /// 用户在通知栏点了结束、甚至在官方 App 里停了。Android 靠前台服务每 15 秒查一次，
    /// 查到就收尾并发通知。iOS 没有前台服务，就用前台任务做同一件事 ——
    /// 少了它，首页那张「使用中的设备」会一直挂着（真机反馈过）。
    ///
    /// ⚠️ 只在前台有效：App 被挂起后任务会被系统冻结。这是系统能力边界，
    /// 回到前台时由 `reconcileOnResume` 补一次。
    func startOrderWatch() {
        guard workScope.isCurrent else { return }
        for record in ActiveOrderStore.all() where watchTasks[record.snCode] == nil {
            let sn = record.snCode
            let token = UUID()
            watchTokens[sn] = token
            AppLog.shared.i("订单监控开始：\(sn)")
            watchTasks[sn] = Task { [weak self] in
                await self?.watch(sn, token: token)
            }
        }
        // 订单已经结束的，任务自己会退出，这里顺手回收
        for (sn, task) in watchTasks where !ActiveOrderStore.isRunning(sn) {
            task.cancel()
            watchTasks[sn] = nil
            watchTokens[sn] = nil
        }
    }

    func stopOrderWatch() {
        for (_, task) in watchTasks { task.cancel() }
        watchTasks.removeAll()
        watchTokens.removeAll()
    }

    /// 单台设备的监控循环 —— 逐条对照 `ShowerWatchService.watch`
    private func watch(_ snCode: String, token: UUID) async {
        if SessionWork.generation == nil {
            await workScope.run(fallback: ()) { await self.watch(snCode, token: token) }
            return
        }
        // 无论从哪条路退出，都要把登记表里的自己摘掉 ——
        // 否则同一台设备下次开阀时会被「已经有任务」挡住，再也不会被监控
        defer {
            if watchTokens[snCode] == token {
                watchTasks[snCode] = nil
                watchTokens[snCode] = nil
            }
        }
        while !Task.isCancelled {
            // 快关停了就精确等到那一刻，否则 15 秒一轮（Android 同）
            let remain = Prefs.autoDisconRemain(snCode)
            let seconds: UInt64 = (remain >= 1 && remain <= 14) ? UInt64(remain) : 15
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if Task.isCancelled { return }
            guard workScope.isCurrent else { return }
            // 别处已经清掉了（用户主动关阀）→ 监控结束
            guard watchTokens[snCode] == token,
                  let watched = ActiveOrderStore.find(snCode) else { return }
            let watchedStart = Prefs.startedAt(snCode)
            // 控制链在等待网络/蓝牙时不能让轮询并行清理同一笔订单。
            if controlGate.isBusy { continue }
            // 蓝牙表**不能**用云端订单判断：它没有 4G，server 的 tcpDevice 通道里
            // 根本没有它的订单，queryUsing 永远 data=null → 会被误判成「订单没了」
            // 而触发自动结算（水其实还在流）。它的结束只来自用户主动停止。
            guard !Prefs.isBleDevice(snCode), watched.isBluetooth == false else { continue }

            switch await CloudShower.orderRunning(snCode: snCode) {
            case .some(true):
                continue
            case .some(false):
                if controlGate.isBusy { continue }
                guard workScope.isCurrent, watchTokens[snCode] == token,
                      ActiveOrderStore.find(snCode) == watched,
                      Prefs.startedAt(snCode) == watchedStart else { continue }
                await finishExternally(snCode)
                return
            case .none:
                continue      // 请求失败 = 不确定，下轮再说（绝不臆断成已结束）
            }
        }
    }

    /// 检测到用水在别处结束：清本地状态 → 通知 → 补结算
    private func finishExternally(_ snCode: String) async {
        guard workScope.isCurrent else { return }
        guard let record = ActiveOrderStore.find(snCode) else { return }
        let startedAt = Prefs.startedAt(snCode)
        let elapsed = startedAt > 0
            ? Int((Int64(Date().timeIntervalSince1970 * 1000) - startedAt) / 1000)
            : 0
        let deviceName = record.deviceName.isEmpty ? "热水器" : record.deviceName
        AppLog.shared.i("订单监控：\(snCode) 在别处结束（用时 \(elapsed)s）")

        let wasDisplayed = activeOrder?.snCode == snCode

        // ⚠️ 先清本地状态：首页「使用中的设备」要立刻消失，
        //    金额晚一点到没关系（Android 也是这个顺序，注释里专门写过）
        markFinished(snCode)
        // ⚠️ 不能 cancel 自己：这个函数就跑在监控任务里，
        // 取消会连带把后面的结算请求一起掐掉
        watchTasks[snCode] = nil

        if wasDisplayed {
            activeOrder = nil
            stopTimer()
        }

        // 「结算中」先挂上，拿到金额后原地更新（对照 Notifier.showSettling → 更新）
        AppNotifications.shared.finished(
            device: deviceName, snCode: snCode, elapsed: elapsed, amount: nil, automatic: true
        )

        let money = await SettlementEngine.settleAmount(
            orderNo: record.orderNo,
            startTimeMs: startedAt,
            snCode: snCode,
            deviceName: deviceName
        )
        guard workScope.isCurrent else { return }
        if var pending = PendingSettlementStore.all().first(where: { $0.snCode == snCode }) {
            pending.elapsedSec = max(0, elapsed)
            PendingSettlementStore.record(pending)
        }
        AppNotifications.shared.finished(
            device: deviceName, snCode: snCode, elapsed: elapsed, amount: money, automatic: true
        )
        if let money, money > 0 {
            Prefs.recordConsume(snCode, amount: money)
            Prefs.lastConsumeYuan = money
        }
        settlementRevision += 1

        // 界面在使用页上就弹自动关停确认框（Android `onShowerFinishedFromService`）
        if wasDisplayed {
            autoClose = AutoCloseNotice(
                deviceName: deviceName,
                elapsedSeconds: elapsed,
                consumed: money,
                loading: false
            )
        } else {
            toast = money.map { $0 > 0 ? "\(deviceName) 已自动关停，本次消费 \(MoneyFormat.withSymbol($0))" : "\(deviceName) 已自动关停，本次无消费" }
                ?? "\(deviceName) 已自动关停，消费金额稍后可在账单中查看"
        }
    }

    // MARK: - 设备占用状态

    /// 每台设备的「订单是不是自己的」。`false` = 他人使用中。
    ///
    /// ⚠️ 必须**按 snCode 记**，不能用全局布尔：查询是异步的，
    /// 全局变量会被后一台设备的响应覆盖（Android v3.0.x 修过这个 bug）。
    @Published private(set) var deviceOwner: [String: Bool] = [:]

    func isOwnerFor(_ snCode: String) -> Bool {
        guard !snCode.isEmpty else { return true }
        return deviceOwner[snCode] ?? true
    }

    /// 查这台设备当前有没有订单、是不是自己的 —— 对照 Android `refreshDeviceStatus`。
    ///
    /// 两个作用，缺一不可：
    /// 1. **他人使用中**：设备详情弹窗据此把按钮置灰（不能拿别人的订单去开阀）
    /// 2. **使用码启动检测**：用物理键盘使用码开机后，扫描到时这里会发现「已经有订单」，
    ///    于是把它记进活跃订单 —— 首页立刻出现「使用中的设备」，用户能直接去关阀
    func refreshDeviceStatus(_ snCode: String) async {
        if SessionWork.generation == nil {
            await workScope.run(fallback: ()) { await self.refreshDeviceStatus(snCode) }
            return
        }
        guard workScope.isCurrent else { return }
        guard !snCode.isEmpty, !controlGate.isBusy else { return }
        let revision = deviceRevisions[snCode, default: 0]
        let accountKey = AppNotifications.accountKey
        guard let q = try? await CloudShower.queryUsing(snCode: snCode) else { return }
        guard !controlGate.isBusy, deviceRevisions[snCode, default: 0] == revision,
              workScope.isCurrent, AppNotifications.accountKey == accountKey else { return }

        let hasOrder = q.errorCode == 307 || (q.success && q.data?.orderNo != nil)
        guard hasOrder else {
            guard q.success else { return }
            ActiveOrderStore.confirmIdle(snCode)
            deviceOwner[snCode] = true
            return
        }

        guard !ActiveOrderStore.wasFinished(snCode: snCode, orderNo: q.data?.orderNo ?? "") else {
            AppLog.shared.i("忽略已结束订单的延迟状态：\(snCode)")
            return
        }

        let owner = q.data?.isOwner ?? true
        deviceOwner[snCode] = owner
        AppLog.shared.i("设备 \(snCode) 已有订单，owner=\(owner)")

        // 只有自己的订单才记进活跃订单；别人的记进去会导致
        // 卡片显示「使用中」、点停止时拿别人的 orderNo 去关阀
        guard owner, ActiveOrderStore.find(snCode) == nil else { return }
        guard let info = cachedDevice(snCode) else { return }
        ActiveOrderStore.upsert(ActiveOrderRecord(
            snCode: snCode,
            orderNo: q.data?.orderNo ?? "",
            deviceName: info.displayName,
            deviceMac: info.macAddress ?? snCode,
            deviceEmoji: info.typeEmoji,
            preDeduct: info.withholdYuan ?? 0,
            // 此入口已查到云端订单；仍尊重已知蓝牙标记，避免误用云端轮询。
            isBluetooth: info.needsBluetoothControl || Prefs.isBleDevice(snCode)
        ))
        if Prefs.startedAt(snCode) <= 0 {
            Prefs.setStartedAt(snCode, Int64(Date().timeIntervalSince1970 * 1000))
        }
        restoredOrders = ActiveOrderStore.all()
    }

    /// 由外部（`MainTabView`）注入，避免这一层依赖扫描器/数据容器。
    /// 返回该 snCode 已扫到的 peripheral（没有则 nil）
    var peripheralProvider: ((String) -> CBPeripheral?)?
    var centralProvider: (() -> CBCentralManager?)?
    var deviceInfoProvider: ((String) -> DeviceInfo?)?

    private func cachedPeripheral(_ sn: String) -> CBPeripheral? { peripheralProvider?(sn) }
    private func cachedCentral() -> CBCentralManager? { centralProvider?() }
    private func cachedDevice(_ sn: String) -> DeviceInfo? { deviceInfoProvider?(sn) }

    private func flowToast(_ text: String) { toast = text }

    /// 开阀时间：**已有持久化值就用它**，没有才记现在。
    ///
    /// ⚠️ 恢复订单时这一点很关键：`startedAt` 如果给成 `Date()`，
    /// 后来拿它做账单时间窗兜底时，窗口就落在「刚点击恢复的那一刻」，
    /// 真正的消费账单在窗口之外——结算永远查不到金额。
    private func startDate(_ sn: String) -> Date {
        guard workScope.isCurrent else { return Date() }
        let ms = Prefs.startedAt(sn)
        if ms > 0 { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        Prefs.setStartedAt(sn, now)
        return Date(timeIntervalSince1970: Double(now) / 1000)
    }

    /// 退出登录 / 会话失效时清干净
    func reset() {
        workScope.cancel()
        ble.disconnect()
        mqtt.disconnect()
        liveConsumed = nil
        activeOrder = nil
        stopTimer()
        lastConsumeYuan = nil
        errorMessage = nil
        bleConfirmDevice = nil
        autoClose = nil
        isStarting = false
        isStopping = false
        openingText = ""
        currentPeripheral = nil
        currentCentral = nil
        deviceRevisions.removeAll()
        stopOrderWatch()
        restoredOrders = ActiveOrderStore.all()
    }
}
