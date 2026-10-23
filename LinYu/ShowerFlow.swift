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

    let ble = BleSession()

    // MARK: - 内部

    private var timer: Timer?
    /// 关阀后要断开重连做结算，必须记住当时的 peripheral / central
    private var currentPeripheral: CBPeripheral?
    private var currentCentral: CBCentralManager?
    private var didFireAutoClose = false
    private var pendingAutoClose = false
    private var lastClosedElapsed = 0
    private var lastAutoCloseElapsed = 0

    init() {
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
                preDeduct: order.preDeductMoney ?? 0
            ))
        }
        restoredOrders = ActiveOrderStore.all()
    }

    /// 清掉这台设备的本地使用状态
    private func clearDeviceState(_ snCode: String) {
        ActiveOrderStore.remove(snCode)
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
    func open(device: DeviceInfo, peripheral: CBPeripheral?, central: CBCentralManager?) async {
        guard activeOrder == nil else {
            toast = "已经有一单在进行中"
            return
        }
        guard !isStarting else { return }

        let sn = device.snCode ?? ""
        guard !sn.isEmpty else {
            errorMessage = "设备信息不完整（缺少 snCode）"
            return
        }

        // 记住连接对象：306 之后用户选「用蓝牙开启」还要用
        currentPeripheral = peripheral
        currentCentral = central

        // ① 服务端标记 ② 用户上次确认过这台要蓝牙
        if device.needsBluetoothControl || Prefs.isBleDevice(sn) {
            await openBle(device, peripheral: peripheral, central: central)
        } else {
            await openCloud(device)
        }
    }

    /// 用户在「要用蓝牙方式开启吗？」里点了确认
    func confirmBleOpen() async {
        guard let device = bleConfirmDevice else { return }
        bleConfirmDevice = nil
        Prefs.markBleDevice(device.snCode ?? "")
        await openBle(device, peripheral: currentPeripheral, central: currentCentral)
    }

    func dismissBleConfirm() {
        bleConfirmDevice = nil
    }

    func clearError() {
        errorMessage = nil
        errorKind = .other
    }

    // MARK: 云端通道

    private func openCloud(_ device: DeviceInfo) async {
        let sn = device.snCode ?? ""
        isStarting = true
        openingText = "正在确认设备是否开启，请稍候"
        defer { isStarting = false }

        AppLog.shared.i("=== 云端开阀 \(device.displayName)（sn=\(sn)）===")

        switch await CloudShower.open(snCode: sn) {
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
            errorMessage = "该设备正在被他人使用"

        case .deviceOffline:
            // 只有站在设备旁的人知道这台是不是蓝牙表 —— 必须问
            bleConfirmDevice = device

        case let .rejected(msg):
            // 服务端明确拒绝：可能是欠费，弹窗里给「立即补扣」入口
            errorKind = .serverRejected
            errorMessage = msg

        case let .failed(msg):
            errorKind = .other
            errorMessage = msg
        }
    }

    // MARK: 蓝牙通道

    private func openBle(_ device: DeviceInfo, peripheral: CBPeripheral?, central: CBCentralManager?) async {
        guard let peripheral, let central else {
            errorMessage = "拿不到设备连接（请重新扫描后再试）"
            return
        }
        isStarting = true
        defer {
            isStarting = false
            openingText = ""
        }

        currentPeripheral = peripheral
        currentCentral = central

        let sn = device.snCode ?? ""
        AppLog.shared.i("=== 蓝牙开阀 \(device.displayName)（sn=\(sn)）===")

        // 1. 连接
        openingText = "正在连接设备…"
        guard await ble.connect(peripheral: peripheral, using: central) else {
            errorMessage = ble.statusText
            return
        }

        // 2. 读状态
        openingText = "正在读取设备状态…"
        guard let st = await ble.query() else {
            ble.disconnect()
            errorMessage = "设备无响应（状态帧读取失败），请靠近设备后重试"
            return
        }

        // 身份核对：状态帧自报的 MAC 必须和要开的那台一致
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
            guard settled.completed else {
                errorMessage = "设备有未结算记录，自动补结算失败，请稍后重试"
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
                if Prefs.startedAt(sn) <= 0 {
                    Prefs.setStartedAt(sn, Int64(Date().timeIntervalSince1970 * 1000))
                }
                activeOrder = ActiveOrder(
                    device: device,
                    snCode: sn,
                    orderNo: rec?.orderNo ?? "",
                    consumeDate: "",
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
            errorMessage = "设备正在被使用（state=\(st.state)）"
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
            rateData = try await ApiClient.post("/order/downRate/bluetooth/rateOrder", form: [
                "deviceId": deviceId,
                "macAddress": expectMac,
                "macType": macType,
                "bigTypeId": String(device.bigTypeId ?? 4),
                "smallTypeId": String(device.smallTypeId ?? 1),
                "protocolType": st.protocolType,
                "randomNumber": st.randomNumber,
                "xfModel": xfModel,
                "signature": signature,
            ], tag: "rateOrder")
        } catch {
            ble.disconnect()
            errorMessage = "申请费率失败：\(error.localizedDescription)"
            return
        }

        let rateResp: APIResponse<BluetoothRateOrderData>
        do {
            rateResp = try ApiClient.decode(BluetoothRateOrderData.self, from: rateData, path: "bluetoothRateOrder")
        } catch {
            ble.disconnect()
            errorMessage = "费率响应异常：\(error.localizedDescription)"
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
            errorMessage = "费率写入未被设备确认，可能没出水（先看日志，别重复点）"
            return
        }

        // 5. 记账
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
        guard let order = activeOrder, !isStopping else { return }
        isStopping = true
        lastClosedElapsed = order.elapsedSeconds
        stopTimer()

        AppLog.shared.i("=== 开始关阀 \(order.snCode)，已用 \(order.elapsedSeconds)s，通道=\(order.channel) ===")

        switch order.channel {
        case .cloud:
            await closeCloud(order)
        case .ble:
            await closeBle(order)
        }

        isStopping = false
    }

    private func closeCloud(_ order: ActiveOrder) async {
        // ⚠️ orderNo 必须在关阀**之前**敲定：关阀成功后订单就没了，
        // `queryUsing` 再也问不出来，后面的结算只能退化成按时间窗猜账单。
        let resolved = await CloudShower.resolveOrderNo(snCode: order.snCode)
        let orderNo = resolved.isEmpty ? order.orderNo : resolved
        let r = await CloudShower.close(snCode: order.snCode, orderNo: orderNo)
        switch r {
        case .closed:
            // 水已关 → 立刻退出使用页
            activeOrder = nil
            Task { await settleCloud(order) }
        case let .unconfirmed(msg):
            // 没有证据 = 水可能还在流。留在页面让用户重试
            toast = "没能确认设备已关闭，请检查网络后重试"
            startTimer()
        case let .failed(msg):
            toast = msg
            startTimer()
        }
    }

    private func closeBle(_ order: ActiveOrder) async {
        let r = await ble.closeValve()

        guard r.waterStopped else {
            // ⚠️ 水可能还在流 —— 留在使用页，让他能重试
            toast = "设备没有响应关闭指令，请靠近设备后重试"
            AppLog.shared.w("蓝牙关阀未确认，保留使用页以便重试")
            startTimer()
            return
        }

        // 水已关：立刻退出使用页，剩下的结算在后台做
        activeOrder = nil
        let wasAutoClosed = pendingAutoClose
        pendingAutoClose = false
        didFireAutoClose = false
        Task { await settleBle(order, autoClosed: wasAutoClosed) }
    }

    // MARK: - 结算

    /// 蓝牙结算（关阀之后调用，此时**已经不在使用页**）
    ///
    /// 六步里第 ② 步「断开重连」是关键：Android 端 2026-09-30 用同一笔订单实测对比过，
    /// 同一连接里「关阀后立刻采集」会被服务端判 226「加密校验失败」、账单停在 0.0；
    /// 断开重连后再采集才被接受。原因是重连后设备才给出新的 `randomNumber`，
    /// 而上传签名用的正是它。
    private func settleBle(_ order: ActiveOrder, autoClosed: Bool = false) async {
        toast = "设备已关闭，正在结算…"

        defer {
            ble.disconnect()
            currentPeripheral = nil
            currentCentral = nil
        }

        guard let p = currentPeripheral, let central = currentCentral else {
            finishWithAmount(nil, autoClosed: autoClosed, deviceName: order.device.displayName)
            return
        }

        // ② 断开 → 重连
        ble.disconnect()
        try? await Task.sleep(nanoseconds: 400_000_000)

        var reconnected = await ble.connect(peripheral: p, using: central)
        if !reconnected {
            try? await Task.sleep(nanoseconds: 500_000_000)
            reconnected = await ble.connect(peripheral: p, using: central)
        }
        guard reconnected else {
            AppLog.shared.w("结算重连失败")
            finishWithAmount(nil, autoClosed: autoClosed, deviceName: order.device.displayName)
            return
        }

        // ③ 重新读状态 —— 要拿**新的** randomNumber / protocolType
        var st: DeviceState?
        for attempt in 1 ... 3 {
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
        if let amount = result.amount {
            Prefs.recordConsume(order.snCode, amount: amount)
        }
        finishWithAmount(result.amount, autoClosed: autoClosed, deviceName: order.device.displayName)
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
            let data = try await ApiClient.post("/order/upload/bluetooth/data", form: [
                "protocolType": protocolType,
                "randomNumber": randomNumber,
                "xfData": xfData,
                "signature": sig,
            ], tag: "upload")
            // ⚠️ 必须用 decodeShell：206/209 是「已受理」的**成功码**，
            // 走 decode 会被当成异常，结算被误判失败、订单被上报作废。
            let resp = try ApiClient.decodeShell(BluetoothUploadData.self, from: data, path: "bluetoothUpload")
            let code = resp.errorCode ?? -1
            let accepted = resp.success || code == 206 || code == 209
            guard accepted, let body = resp.data else {
                if code == 170 {
                    AppLog.shared.e("结算上传被拒（170）：签名与上传字段不一致，请带日志反馈")
                }
                AppLog.shared.w("结算上传失败（errorCode=\(code)）：\(resp.displayMessage ?? "")")
                return (false, nil)
            }

            let yuan = body.upMoneyYuan

            // ③ 写回设备（清掉离线记录）；写回失败不影响——服务端已经记账
            if let clData = body.clData, !clData.isEmpty,
               let plain = KlcxkjCrypto.decryptByAes(clData) {
                let hexPart = plain.contains("-")
                    ? String(plain.split(separator: "-", maxSplits: 1).last ?? "")
                    : plain
                if let bytes = BleFrame.fromHex(hexPart), !bytes.isEmpty {
                    let ok = await ble.writeBack(bytes)
                    AppLog.shared.i(ok ? "0x86 写回成功，设备记录已清" : "0x86 写回失败（服务端已记账）")
                }
            }
            AppLog.shared.i("结算上传成功：设备=\(deviceName) orderNo=\(orderNo) upMoney=\(body.upMoney?.value ?? body.consumeMoney?.value ?? -1)")
            _ = consumeDate
            return (true, yuan)
        } catch {
            AppLog.shared.w("上传结算失败：\(error.localizedDescription)")
            return (false, nil)
        }
    }

    private func settleCloud(_ order: ActiveOrder) async {
        toast = "设备已关闭，正在结算…"
        // 与 Android 的 `SettlementEngine.settleAmount` 完全同一条路：
        // 直答接口 → 零确认 → 账单列表回退 → 登记待对账
        let yuan = await SettlementEngine.settleAmount(
            orderNo: order.orderNo,
            startTimeMs: Int64(order.startedAt.timeIntervalSince1970 * 1000),
            snCode: order.snCode,
            deviceName: order.device.displayName
        )
        finishWithAmount(yuan, autoClosed: false, deviceName: order.device.displayName)
    }

    /// 结算完成：记金额、弹提示（或自动关停弹窗）
    private func finishWithAmount(_ yuan: Double?, autoClosed: Bool, deviceName: String) {
        AppNotifications.shared.finished(device: deviceName,
            elapsed: autoClosed ? lastAutoCloseElapsed : lastClosedElapsed,
            amount: yuan, automatic: autoClosed)
        lastConsumeYuan = yuan
        settlementRevision += 1
        if let yuan, yuan > 0 { Prefs.lastConsumeYuan = yuan }

        if autoClosed {
            // 自动关停：弹窗说清楚「为什么关了 + 花了多少」
            autoClose = AutoCloseNotice(
                deviceName: deviceName,
                elapsedSeconds: lastAutoCloseElapsed,
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
        guard let order = activeOrder else { return }
        objectWillChange.send()

        // 自动关停：对照 Android，**倒计时是持久化的截止时间戳**，
        // 所以切后台、锁屏都不会把它推迟。
        //
        // ⚠️ Android 由前台服务 `ShowerWatchService` 执行关阀，iOS 没那种常驻能力，
        // 只能在前台（或回到前台那一刻）发现到点并主动关阀——这是系统限制，
        // 不是实现偷懒。回到前台的对齐见 `reconcileOnResume()`。
        guard order.autoDisConSec > 0, !didFireAutoClose, !isStopping else { return }
        if Prefs.autoDisconRemain(order.snCode) <= 0 {
            didFireAutoClose = true
            pendingAutoClose = true
            lastAutoCloseElapsed = order.elapsedSeconds
            AppLog.shared.i("到达自动关停时间（\(order.autoDisConSec)s），主动关阀")
            Task { await close() }
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
            if running == false {
                AppLog.shared.i("回前台对齐：服务端已无订单，退出使用页")
                activeOrder = nil
                stopTimer()
                toast = "设备已关闭"
                Task { await settleCloud(order) }
            }
        }
    }

    /// 复核待对账记录 —— 对照 Android `SettlementReconciler` 的周期对账。
    ///
    /// 拉一次账单列表，能匹配上的就把金额补上并弹提示，匹配不上的继续留着。
    @discardableResult
    func reconcileSettlements() async -> [SettlementUpdate] {
        let pending = PendingSettlementStore.all()
        guard !pending.isEmpty else { return [] }

        guard let bills = await BillService.loadHistoryOrNil() else {
            AppLog.shared.w("待对账复核：账单拉取失败，保留 \(pending.count) 条")
            return []
        }
        let result = SettlementReconciler.reconcile(pending: pending, bills: bills)
        PendingSettlementStore.save(result.remaining)

        for update in result.updates {
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
    /// ## 为什么要重新走一遍开阀流程
    ///
    /// 恢复**不是**纯本地操作：内存里的连接对象早就没了，必须先拿到设备台账，
    /// 再让通道自己确认（云端查 `queryUsing`、蓝牙读状态帧）。
    /// 两边都会回「已有订单、是你的」→ 直接沿用，**不会重新开阀、不会重复扣预扣**。
    func resume(record: ActiveOrderRecord) async {
        guard activeOrder == nil else { return }
        let sn = record.snCode
        guard !sn.isEmpty else { return }

        // 台账：优先内存缓存，其次服务端
        let info: DeviceInfo
        if let cached = cachedDevice(sn) {
            info = cached
        } else {
            do {
                let data = try await ApiClient.get(
                    "/device/info/mac",
                    query: ["macAddress": sn],
                    tag: "deviceInfo"
                )
                let resp = try ApiClient.decodeShell(DeviceInfo.self, from: data, path: "deviceInfo")
                guard resp.success, let d = resp.data else {
                    flowToast("获取设备信息失败，稍后重试")
                    return
                }
                info = d
            } catch {
                flowToast("获取设备信息失败：\(error.localizedDescription)")
                return
            }
        }

        // ⚠️ 必须真的扫到这台设备才能走蓝牙：CoreBluetooth 只认 `CBPeripheral`，
        // 没扫到就无法连接。这里不清掉记录，只提示去附近设备里选。
        if info.needsBluetoothControl || Prefs.isBleDevice(sn) {
            if let p = cachedPeripheral(sn), let central = cachedCentral() {
                await open(device: info, peripheral: p, central: central)
            } else {
                flowToast("这台是蓝牙表，请从「附近设备」里选它（需要先扫描到）")
            }
            return
        }
        await open(device: info, peripheral: nil, central: nil)
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
        let ms = Prefs.startedAt(sn)
        if ms > 0 { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        Prefs.setStartedAt(sn, now)
        return Date(timeIntervalSince1970: Double(now) / 1000)
    }

    /// 退出登录 / 会话失效时清干净
    func reset() {
        ble.disconnect()
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
        restoredOrders = ActiveOrderStore.all()
    }
}
