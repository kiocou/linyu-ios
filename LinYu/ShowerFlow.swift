import Foundation
import CoreBluetooth
import Combine

/// 一次用水的本地记录
struct ActiveOrder {
    let device: DeviceInfo
    let snCode: String
    let orderNo: String
    let consumeDate: String
    let protocolType: String
    let randomNumber: String
    let startedAt: Date
    let preDeductMoney: Double?

    var elapsedSeconds: Int { max(0, Int(Date().timeIntervalSince(startedAt))) }
}

/// 开阀 / 关阀 / 结算的**业务编排**。对照 Android 的 `BleShowerController`。
///
/// ## 蓝牙通道和 4G 通道是两条完全独立的路
///
/// - `tcpDevice/*`：云端把指令推给设备，要求设备自带 4G
/// - `bluetooth/*`：**手机当网关**，服务端只下发费率包，阀由手机写进设备
///
/// 对蓝牙表调 `tcpDevice` 必然回 `306 设备不在线`。
@MainActor
final class ShowerFlow: ObservableObject {

    enum Stage: Equatable {
        case idle
        case connecting
        case querying
        case requestingRate
        case writingRate
        case inUse
        case closing
        case collecting
        case uploading
        case writingBack
        case done
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "空闲"
            case .connecting: return "正在连接设备…"
            case .querying: return "读取设备状态…"
            case .requestingRate: return "向云端申请费率…"
            case .writingRate: return "写入费率并开阀…"
            case .inUse: return "正在用水"
            case .closing: return "正在关阀…"
            case .collecting: return "读取消费数据…"
            case .uploading: return "上传消费数据…"
            case .writingBack: return "写回设备记录…"
            case .done: return "已完成"
            case .failed(let m): return "失败：\(m)"
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var activeOrder: ActiveOrder?
    /// 上一次结算的金额（元）
    @Published private(set) var lastConsumeYuan: Double?

    let ble = BleSession()

    private var timer: Timer?
    /// 关阀后要断开重连，必须记住当时的 peripheral 和 central
    private var currentPeripheral: CBPeripheral?
    private var currentCentral: CBCentralManager?

    // MARK: - 开阀

    /// 完整开阀流程
    func open(device: DeviceInfo, peripheral: CBPeripheral, central: CBCentralManager) async {
        guard activeOrder == nil else {
            stage = .failed("已经有一单在进行中")
            return
        }
        AppLog.shared.i("=== 开始开阀 \(device.displayName)（sn=\(device.snCode ?? "-")）===")

        currentPeripheral = peripheral
        currentCentral = central

        // 1. 连接
        stage = .connecting
        guard await ble.connect(peripheral: peripheral, using: central) else {
            stage = .failed(ble.statusText)
            return
        }

        // 2. 查状态
        stage = .querying
        guard let st = await ble.query() else {
            ble.disconnect()
            stage = .failed("设备无响应（状态帧读取失败）")
            return
        }

        // 设备身份核对：状态帧里的 MAC 必须和我们要开的那台一致
        let expectMac = device.connectMac
        if !st.mac.isEmpty && !expectMac.isEmpty && st.mac.uppercased() != expectMac.uppercased() {
            ble.disconnect()
            stage = .failed("连错设备了（设备报 \(st.mac)）")
            AppLog.shared.e("设备身份不匹配：期望 \(expectMac)，实际 \(st.mac)")
            return
        }

        if st.hasPendingSettle {
            ble.disconnect()
            stage = .failed("设备有上一笔未结算记录（state=\(st.state)），请先用安卓端结清一次")
            return
        }
        guard st.isIdle else {
            ble.disconnect()
            stage = .failed("设备正在被使用（state=\(st.state)）")
            return
        }

        // 3. 向云端申请费率包
        stage = .requestingRate
        let sn = device.snCode ?? st.mac
        guard let deviceId = device.deviceId.map(String.init) else {
            ble.disconnect()
            stage = .failed("设备缺少 deviceId")
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
            stage = .failed("签名计算失败（登录态可能失效）")
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
                "signature": signature
            ], tag: "rateOrder")
        } catch {
            ble.disconnect()
            stage = .failed("申请费率失败：\(error.localizedDescription)")
            return
        }

        let rateResp: APIResponse<BluetoothRateOrderData>
        do {
            rateResp = try ApiClient.decode(BluetoothRateOrderData.self, from: rateData, path: "bluetoothRateOrder")
        } catch {
            ble.disconnect()
            stage = .failed("费率响应异常：\(error.localizedDescription)")
            return
        }

        guard let downHex = rateResp.data?.downData,
              let downBytes = BleFrame.fromHex(downHex),
              !downBytes.isEmpty
        else {
            ble.disconnect()
            stage = .failed("云端没返回有效费率包")
            return
        }
        AppLog.shared.i("云端下发费率包 \(downBytes.count)B")

        // 4. 写入设备（真正开阀）
        stage = .writingRate
        let ok = await ble.writeRate(downBytes)
        if !ok {
            ble.disconnect()
            stage = .failed("费率写入未被设备确认，可能没出水（也别重复试，先看日志）")
            return
        }

        // 5. 记账
        let orderNo = rateResp.data?.orderNo ?? ""
        let consumeDate = rateResp.data?.consumeDate ?? ""
        activeOrder = ActiveOrder(
            device: device,
            snCode: sn,
            orderNo: orderNo,
            consumeDate: consumeDate,
            protocolType: st.protocolType,
            randomNumber: st.randomNumber,
            startedAt: Date(),
            preDeductMoney: rateResp.data?.preDeductYuan
        )
        stage = .inUse
        startTimer()
        AppLog.shared.i("✅ 开阀成功 orderNo=\(orderNo) consumeDate=\(consumeDate)")
    }

    // MARK: - 关阀 + 结算

    /// 关阀并结算。
    ///
    /// ## ⚠️ 关阀后必须**断开重连**再采集
    ///
    /// Android 端 2026-09-30 用同一笔订单实测对比：
    /// - 同一连接里「关阀后立刻采集」→ 服务端判 **226「加密校验失败」**，账单停在 0.0
    /// - **断开重连后**再采集 → 服务端接受，结算成功
    ///
    /// 原因是重连后设备才会给出新的 `randomNumber`，而上传签名用的正是它；
    /// 同一连接里拿到的是开阀时的旧值，服务端重算签名对不上。
    func close() async {
        guard let order = activeOrder else {
            stage = .failed("没有进行中的订单")
            return
        }
        stopTimer()
        AppLog.shared.i("=== 开始关阀 \(order.snCode)，已用 \(order.elapsedSeconds)s ===")

        // ① 关阀
        stage = .closing
        let closed = await ble.closeValve()
        if !closed {
            // 设备可能已经关了（实测第二次 0x22 返回 81 01 = 已关闭），继续走结算
            AppLog.shared.w("0x22 关阀未确认，继续尝试结算")
        }

        // ② 断开 → 重连（226 的关键）
        guard let p = currentPeripheral, let central = currentCentral else {
            stage = .failed("缺少设备连接信息，无法完成结算")
            return
        }
        ble.disconnect()
        try? await Task.sleep(nanoseconds: 400_000_000)

        stage = .collecting
        var reconnected = await ble.connect(peripheral: p, using: central)
        if !reconnected {
            // BLE 栈偶尔还没处理完上一次断开，稍等再试一次
            try? await Task.sleep(nanoseconds: 500_000_000)
            reconnected = await ble.connect(peripheral: p, using: central)
        }
        guard reconnected else {
            stage = .failed("设备已关闭，但重连失败，结算未完成（下次连接会自动结清）")
            return
        }

        // ③ 重新查状态 —— 必须用这里的 randomNumber / protocolType
        guard let st = await ble.query() else {
            stage = .failed("设备已关闭，但读取状态失败，下次连接会自动结清")
            return
        }
        AppLog.shared.i("关阀重连后状态：\(st.describe)")

        // ④ 采集
        guard let payload = await ble.collect() else {
            stage = .failed("采集消费数据失败，设备可能停在未结算状态（state=\(st.state)）")
            return
        }
        guard payload.count >= 42, payload.first == 0x80 else {
            let firstHex = payload.first.map { String(format: "0x%02X", $0) } ?? "空"
            AppLog.shared.w("消费数据无效（\(payload.count)B，首字节 \(firstHex)）")
            stage = .failed("设备返回的消费数据无效，请靠近后重试")
            return
        }

        // ⑤ 上传（xfData 必须小写；protocolType / randomNumber 用重连后的）
        stage = .uploading
        let xfData = BleFrame.toHex(payload).lowercased()
        guard let sig = BleSign.signUpload(
            loginCode: Session.shared.loginCode,
            telephone: Session.shared.telephone,
            xfData: xfData
        ) else {
            stage = .failed("签名失败，无法上传结算")
            return
        }

        let uploadData: Data
        do {
            uploadData = try await ApiClient.post("/order/upload/bluetooth/data", form: [
                "protocolType": st.protocolType,
                "randomNumber": st.randomNumber,
                "xfData": xfData,
                "signature": sig
            ], tag: "upload")
        } catch {
            stage = .failed("上传结算失败：\(error.localizedDescription)")
            await reportFail(order)
            return
        }

        let uploadResp: APIResponse<BluetoothUploadData>
        do {
            uploadResp = try ApiClient.decode(BluetoothUploadData.self, from: uploadData, path: "bluetoothUpload")
        } catch {
            stage = .failed("结算响应异常：\(error.localizedDescription)")
            await reportFail(order)
            return
        }

        let upMoney = uploadResp.data?.upMoneyYuan ?? 0
        lastConsumeYuan = upMoney
        AppLog.shared.i("✅ 结算上传成功，金额 \(upMoney) 元")

        // ⑥ 写回设备（清掉离线记录）；失败不阻塞——服务端已经记账
        stage = .writingBack
        if let clData = uploadResp.data?.clData, !clData.isEmpty,
           let plain = KlcxkjCrypto.decryptByAes(clData) {
            let hexPart = plain.contains("-")
                ? String(plain.split(separator: "-", maxSplits: 1).last ?? "")
                : plain
            if let bytes = BleFrame.fromHex(hexPart), !bytes.isEmpty {
                let ok = await ble.writeBack(bytes)
                AppLog.shared.i(ok ? "0x86 写回成功，设备记录已清" : "0x86 写回失败（服务端已记账）")
            } else {
                AppLog.shared.w("clData 解密后不是合法 hex：\(hexPart.prefix(60))")
            }
        } else {
            AppLog.shared.w("服务端没给 clData，跳过写回")
        }

        ble.disconnect()
        activeOrder = nil
        currentPeripheral = nil
        currentCentral = nil
        stage = .done
    }

    /// 结算失败时向服务端上报作废
    ///
    /// ⚠️ 这是**必须实现**的：蓝牙开阀没有服务端兜底，费率包下发后如果没正常结算，
    /// 设备侧可能停在「开了但没记账」，得靠它告诉服务端这单作废。
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
                "signature": sig
            ], tag: "fail")
            AppLog.shared.i("已上报失败订单（作废）")
        } catch {
            AppLog.shared.w("上报失败订单也失败了：\(error.localizedDescription)")
        }
    }

    // MARK: - 计时

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.activeOrder != nil {
                self.objectWillChange.send()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        ble.disconnect()
        activeOrder = nil
        stage = .idle
        lastConsumeYuan = nil
        stopTimer()
    }
}
