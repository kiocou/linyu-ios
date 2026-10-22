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

    var elapsedSeconds: Int { max(0, Int(Date().timeIntervalSince(startedAt))) }

    /// 自动关停倒计时（秒）。没有这个配置时是 0，界面不显示那一行
    var autoDisConRemain: Int {
        guard autoDisConSec > 0 else { return 0 }
        return max(0, autoDisConSec - elapsedSeconds)
    }
}

enum ShowerChannel {
    /// 云端 `tcpDevice/*`：服务端推给设备（要求 4G）
    case cloud
    /// 蓝牙 `bluetooth/*`：手机当网关
    case ble
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

    @Published private(set) var activeOrder: ActiveOrder?
    /// 「正在开启」弹窗是否显示
    @Published private(set) var isStarting = false
    /// 开启进度文案（蓝牙表要好几步，不给进度用户会以为卡死）
    @Published private(set) var openingText = ""
    /// 开阀失败文案（非 nil 就弹窗）
    @Published var errorMessage: String?
    /// 306 之后要问用户「要不要改用蓝牙」
    @Published var bleConfirmDevice: DeviceInfo?
    /// 轻提示
    @Published var toast: String?
    @Published private(set) var isStopping = false
    @Published private(set) var lastConsumeYuan: Double?
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
                startedAt: Date(),
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
                startedAt: Date(),
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

        case let .failed(msg):
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
            ble.disconnect()
            errorMessage = "设备有上一笔未结算记录（state=\(st.state)），请先用安卓端结清一次"
            return
        }
        guard st.isIdle else {
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
            startedAt: Date(),
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
        let r = await CloudShower.close(snCode: order.snCode, orderNo: order.orderNo)
        switch r {
        case .closed:
            // 水已关 → 立刻退出使用页
            activeOrder = nil
            Task { await settleCloud(order) }
        case let .unconfirmed(msg):
            // 没有证据 = 水可能还在流。留在页面让用户重试
            toast = "没能确认设备已关闭（\(msg)），请检查网络后重试"
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

        // ④ 采集
        guard let payload = await ble.collect() else {
            AppLog.shared.w("0x85 采集失败")
            finishWithAmount(nil, autoClosed: autoClosed, deviceName: order.device.displayName)
            return
        }
        guard payload.count >= 42, payload.first == 0x80 else {
            let firstHex = payload.first.map { String(format: "0x%02X", $0) } ?? "空"
            AppLog.shared.w("消费数据无效（\(payload.count)B，首字节 \(firstHex)）")
            finishWithAmount(nil, autoClosed: autoClosed, deviceName: order.device.displayName)
            return
        }

        // ⑤ 上传（xfData 必须小写）
        let xfData = BleFrame.toHex(payload).lowercased()
        guard let sig = BleSign.signUpload(
            loginCode: Session.shared.loginCode,
            telephone: Session.shared.telephone,
            xfData: xfData
        ) else {
            finishWithAmount(nil, autoClosed: autoClosed, deviceName: order.device.displayName)
            return
        }

        do {
            let data = try await ApiClient.post("/order/upload/bluetooth/data", form: [
                "protocolType": protocolType,
                "randomNumber": randomNumber,
                "xfData": xfData,
                "signature": sig,
            ], tag: "upload")
            let resp = try ApiClient.decode(BluetoothUploadData.self, from: data, path: "bluetoothUpload")

            let yuan = resp.data?.upMoneyYuan
            finishWithAmount(yuan, autoClosed: autoClosed, deviceName: order.device.displayName)

            // ⑥ 写回设备（清掉离线记录）；失败不影响——服务端已经记账
            if let clData = resp.data?.clData, !clData.isEmpty,
               let plain = KlcxkjCrypto.decryptByAes(clData) {
                let hexPart = plain.contains("-")
                    ? String(plain.split(separator: "-", maxSplits: 1).last ?? "")
                    : plain
                if let bytes = BleFrame.fromHex(hexPart), !bytes.isEmpty {
                    let ok = await ble.writeBack(bytes)
                    AppLog.shared.i(ok ? "0x86 写回成功，设备记录已清" : "0x86 写回失败（服务端已记账）")
                }
            }
        } catch {
            AppLog.shared.w("上传结算失败：\(error.localizedDescription)")
            finishWithAmount(nil, autoClosed: autoClosed, deviceName: order.device.displayName)
            await reportFail(order)
        }
    }

    private func settleCloud(_ order: ActiveOrder) async {
        toast = "设备已关闭，正在结算…"
        let yuan = await CloudShower.settle(orderNo: order.orderNo, snCode: order.snCode)
        finishWithAmount(yuan, autoClosed: false, deviceName: order.device.displayName)
    }

    /// 结算完成：记金额、弹提示（或自动关停弹窗）
    private func finishWithAmount(_ yuan: Double?, autoClosed: Bool, deviceName: String) {
        lastConsumeYuan = yuan
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
                : "已停止，本次无消费（\(lastClosedElapsed)秒）"
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

        // 云端表有 autoDisConTime（如 600 秒）。到点由**服务端**关阀，
        // iOS 没有后台常驻服务，只能在前台把这件事告诉用户
        guard order.autoDisConSec > 0, !didFireAutoClose, !isStopping else { return }
        if order.elapsedSeconds >= order.autoDisConSec {
            didFireAutoClose = true
            pendingAutoClose = true
            lastAutoCloseElapsed = order.elapsedSeconds
            AppLog.shared.i("到达自动关停时间（\(order.autoDisConSec)s），主动关阀")
            Task { await close() }
        }
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
    }
}
