import Foundation
import CoreBluetooth
import Combine


/// 蓝牙水表会话：连接、服务发现、分片收发、以及五条业务命令。
///
/// 逐条对照 Android 的 `ble/BleController.kt`。
///
/// ## 三个必须遵守的时序
///
/// 1. **连上不代表可用**：要等 `didDiscoverServices` + `didUpdateNotificationStateFor`
///    全部完成后才能写命令，否则写出去了设备也不会理。
/// 2. **分片必须逐片等回执**：BLE 单次写入上限 MTU-3（默认 20 字节），
///    一帧 HEX 文本动辄上百字节；连续写不等回执，设备会丢片。
/// 3. **发命令前先清残留帧**：设备会主动推上一笔未结算的 `0x22`+`0x85`，
///    不清掉就会把旧帧当作本次应答（Android 端踩过，导致账单串单）。
@MainActor
final class BleSession: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case connecting
        case discovering
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText = "未连接"
    /// 最近一次发现到的 GATT 结构（给诊断页看）
    @Published private(set) var gattLines: [String] = []

    // MARK: 常量

    private static let serviceUUID = CBUUID(string: "FF00")
    private static let notifyUUID = CBUUID(string: "FF01")
    private static let writeUUID = CBUUID(string: "FF02")

    private static let chunkSize = 20
    private static let chunkGapNs: UInt64 = 20_000_000   // 20ms

    static let cmdQuery: UInt8 = 0x23
    static let cmdRate: UInt8 = 0x21
    static let cmdClose: UInt8 = 0x22
    static let cmdCollect: UInt8 = 0x85
    static let cmdWriteBack: UInt8 = 0x86

    private static let ackOK: UInt8 = 0x80

    // MARK: 内部

    /// ⚠️ 必须复用扫描器的 central：用另一个 central 连接会报 invalid parameters
    weak var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var connectContinuation: CheckedContinuation<Bool, Never>?
    /// 当前这一片写入的序号（超时闭包靠它判断「还是不是我这片」）
    private var writeToken = 0
    /// 单片写入超时（秒）
    static let writeTimeout: TimeInterval = 3
    private var writeContinuation: CheckedContinuation<Bool, Never>?
    private var replyWaiters: [UInt8: CheckedContinuation<[UInt8]?, Never>] = [:]
    private var rxBuffer = Data()

    private var servicesPending = 0
    private var notifyEnabled = false
    private var connectTimeoutWork: DispatchWorkItem?

    override init() {
        super.init()
        // central 由 BLEScanner 注入（见 HomeView），不在这里创建
    }

    // MARK: - 连接
    var operationAllowed: () -> Bool = { true }
    private var canOperate: Bool { !Task.isCancelled && operationAllowed() }

    /// 用扫描到的 `CBPeripheral` 连接（**iOS 唯一可行的方式**）
    @discardableResult
    func connect(
        peripheral p: CBPeripheral,
        using manager: CBCentralManager,
        timeout: TimeInterval = 15
    ) async -> Bool {
        guard canOperate else { return false }
        central = manager
        guard let central else { return false }
        guard central.state == .poweredOn else {
            setPhase(.failed("蓝牙未开启（\(describe(central.state))）"))
            return false
        }

        // 干净地断开上一次
        if let old = peripheral {
            central.cancelPeripheralConnection(old)
        }
        resetBuffers()

        peripheral = p
        p.delegate = self
        setPhase(.connecting)

        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            connectContinuation = cont

            // 超时兜底：绝不能无限等
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .connecting || self.phase == .discovering else { return }
                self.setPhase(.failed("连接超时（\(Int(timeout))s），可能信号太弱，请靠近设备"))
                self.connectContinuation?.resume(returning: false)
                self.connectContinuation = nil
                if let p = self.peripheral {
                    self.central?.cancelPeripheralConnection(p)
                }
            }
            connectTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)

            AppLog.shared.i("BLE 开始连接 \(p.identifier.uuidString.prefix(8))…")
            central.connect(p, options: nil)
        }

        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil

        guard canOperate else { disconnect(); return false }
        if ok {
            setPhase(.ready)
            AppLog.shared.i("BLE 就绪：FF00/FF01/FF02 齐全，通知已开启")
        }
        return ok
    }

    func disconnect() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        connectContinuation?.resume(returning: false)
        connectContinuation = nil
        if let p = peripheral, let central {
            central.cancelPeripheralConnection(p)
        }
        resetBuffers()
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        notifyEnabled = false
        setPhase(.idle)
        statusText = "已断开"
    }

    // MARK: - 五条命令

    /// 查询状态 `0x23`（**只读**）
    func query(timeout: TimeInterval = 8) async -> DeviceState? {
        guard phase == .ready else {
            AppLog.shared.w("BLE 未就绪，无法查询（phase=\(phase)）")
            return nil
        }
        // 清掉可能残留的主动推帧
        drainIncoming()

        guard let payload = await sendAndAwait(cmd: Self.cmdQuery, data: [0], timeout: timeout) else {
            AppLog.shared.w("0x23 无应答")
            return nil
        }
        guard let st = Self.parseState(payload) else {
            AppLog.shared.w("0x23 载荷无法解析（\(payload.count)B）")
            return nil
        }
        AppLog.shared.i("状态：\(st.describe)，MAC=\(st.mac)")
        return st
    }

    /// 下发费率包 `0x21`（**真正开阀**）
    ///
    /// - Parameter downData: 服务端 `bluetoothRateOrder` 返回的 `downData` 解码结果。
    ///   **必须原样使用**，不能改一个字节。
    func writeRate(_ downData: [UInt8], timeout: TimeInterval = 10) async -> Bool {
        guard phase == .ready else { return false }
        drainIncoming()
        guard let payload = await sendAndAwait(cmd: Self.cmdRate, data: downData, timeout: timeout) else {
            AppLog.shared.w("0x21 无应答")
            return false
        }
        let ok = payload.first == Self.ackOK
        AppLog.shared.i("0x21 下发费率\(ok ? "成功" : "失败")：\(BleFrame.toHexSpaced(payload))")
        return ok
    }

    /// 关阀结果。
    ///
    /// 为什么不是 Bool：`0x22` 有三种有意义的结局，混成「成功/失败」会让上层做错事——
    /// - `.alreadyClosed`（实测返回 `81 01`）是**水已经关了**，必须继续结算，
    ///   不能提示「关阀失败」让用户反复点
    /// - `.noReply` 才是真的没有证据，这时水可能还在流，**不能退出使用页**
    enum ValveCloseResult {
        case ok
        case alreadyClosed
        case noReply

        var waterStopped: Bool { self == .ok || self == .alreadyClosed }
    }

    /// 关阀 `0x22`
    func closeValve(timeout: TimeInterval = 8) async -> ValveCloseResult {
        guard phase == .ready else {
            AppLog.shared.w("0x22 未能发送：BLE 未就绪（\(phase)）")
            return .noReply
        }
        drainIncoming()
        guard let payload = await sendAndAwait(cmd: Self.cmdClose, data: [0], timeout: timeout) else {
            AppLog.shared.w("0x22 无应答")
            return .noReply
        }
        if payload.first == Self.ackOK {
            AppLog.shared.i("0x22 关阀成功：\(BleFrame.toHexSpaced(payload))")
            return .ok
        }
        // `81 01` = 设备已处于关闭状态（重复关阀时会出现）
        if payload.first == 0x81 {
            AppLog.shared.i("0x22 设备已是关闭状态：\(BleFrame.toHexSpaced(payload))")
            return .alreadyClosed
        }
        AppLog.shared.w("0x22 关阀失败：\(BleFrame.toHexSpaced(payload))")
        return .noReply
    }

    /// 采集消费数据 `0x85`
    func collect(timeout: TimeInterval = 10) async -> [UInt8]? {
        guard phase == .ready else { return nil }
        drainIncoming()
        guard let payload = await sendAndAwait(cmd: Self.cmdCollect, data: [0], timeout: timeout) else {
            AppLog.shared.w("0x85 无应答")
            return nil
        }
        AppLog.shared.i("0x85 采集到 \(payload.count)B")
        return payload
    }

    /// 写回设备存储 `0x86`（清掉设备侧离线记录）
    func writeBack(_ data: [UInt8], timeout: TimeInterval = 10) async -> Bool {
        guard phase == .ready else { return false }
        drainIncoming()
        guard let payload = await sendAndAwait(cmd: Self.cmdWriteBack, data: data, timeout: timeout) else {
            AppLog.shared.w("0x86 无应答")
            return false
        }
        let ok = payload.first == Self.ackOK
        AppLog.shared.i("0x86 写回\(ok ? "成功" : "失败")")
        return ok
    }

    // MARK: - 收发核心

    /// 发一条命令并等对应 cmd 的应答
    private func sendAndAwait(cmd: UInt8, data: [UInt8], timeout: TimeInterval) async -> [UInt8]? {
        guard canOperate else { return nil }
        let wire = BleFrame.cmdToWire(cmd: cmd, data: data)
        AppLog.shared.i("→ BLE 发 0x\(String(cmd, radix: 16))（\(wire.count)B）",
                        BleFrame.toHex(wire))

        guard await writeChunks(wire) else {
            AppLog.shared.w("0x\(String(cmd, radix: 16)) 写入失败")
            return nil
        }
        guard canOperate else { return nil }
        return await awaitReply(cmd: cmd, timeout: timeout)
    }

    /// 分片写入 FF02，逐片等回执
    private func writeChunks(_ wire: [UInt8]) async -> Bool {
        guard let peripheral, let char = writeChar else { return false }

        var offset = 0
        var index = 0
        while offset < wire.count {
            guard canOperate else { return false }
            let len = min(Self.chunkSize, wire.count - offset)
            let chunk = Array(wire[offset..<(offset + len)])

            writeToken += 1
            let token = writeToken
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                writeContinuation = cont
                // ⚠️ 每片必须有自己的超时：`didWriteValueFor` 可能因为断开、
                // 特征被回收、或设备在过渡态而不回调。没有超时的话
                // `close()` 会**永久卡在 writeChunks**——真机上表现为
                // 「一直显示正在关闭」，用户只能杀进程。
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeTimeout) { [weak self] in
                    guard let self, self.writeToken == token,
                          let c = self.writeContinuation else { return }
                    self.writeContinuation = nil
                    AppLog.shared.w("分片 \(index) 写入超时（\(Int(Self.writeTimeout))s）")
                    c.resume(returning: false)
                }
                peripheral.writeValue(Data(chunk), for: char, type: .withResponse)
            }

            if !ok {
                AppLog.shared.w("分片 \(index) 写入失败（offset=\(offset)）")
                return false
            }

            offset += len
            index += 1
            if offset < wire.count {
                try? await Task.sleep(nanoseconds: Self.chunkGapNs)
            }
        }
        return true
    }

    /// 等某个命令字的应答
    private func awaitReply(cmd: UInt8, timeout: TimeInterval) async -> [UInt8]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
            replyWaiters[cmd] = cont

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                if let w = self.replyWaiters.removeValue(forKey: cmd) {
                    AppLog.shared.w("等待 0x\(String(cmd, radix: 16)) 应答超时")
                    w.resume(returning: nil)
                }
            }
        }
    }

    /// 收帧：累积 → 按 0x0A 切 → 校验 → 分发
    private func appendAndDispatch(_ bytes: [UInt8]) {
        rxBuffer.append(contentsOf: bytes)
        let all = [UInt8](rxBuffer)

        var frames: [[UInt8]] = []
        var start = 0
        for i in all.indices where all[i] == BleFrame.wireEnd {
            frames.append(Array(all[start...i]))
            start = i + 1
        }
        rxBuffer = Data(all[start...])

        for f in frames {
            guard let frame = BleFrame.parseWire(f) else {
                AppLog.shared.w("收帧非法（CRC/格式）：\(BleFrame.toHex(f))")
                continue
            }
            let cmd = BleFrame.cmdOf(frame)
            let payload = BleFrame.payloadOf(frame) ?? []
            AppLog.shared.i("← BLE 收 0x\(String(cmd, radix: 16))（\(payload.count)B）",
                            BleFrame.toHexSpaced(payload))

            if let waiter = replyWaiters.removeValue(forKey: cmd) {
                waiter.resume(returning: payload)
            }
        }
    }

    /// 丢掉残留帧（设备会主动推上一笔未结算数据）
    private func drainIncoming() {
        rxBuffer.removeAll()
        // 把没有等待者的旧帧清掉由 appendAndDispatch 的 waiter 机制自然处理；
        // 这里只需要保证缓冲区是空的，避免半截帧混进本次应答
    }

    private func resetBuffers() {
        rxBuffer.removeAll()
        replyWaiters.values.forEach { $0.resume(returning: nil) }
        replyWaiters.removeAll()
        writeContinuation?.resume(returning: false)
        writeContinuation = nil
        servicesPending = 0
        notifyEnabled = false
        gattLines.removeAll()
    }

    // MARK: - 解析

    static func parseState(_ payload: [UInt8]) -> DeviceState? {
        DeviceStateParser.parse(payload)
    }

    // MARK: - 工具

    private func setPhase(_ p: Phase) {
        phase = p
        switch p {
        case .idle: statusText = "未连接"
        case .connecting: statusText = "正在连接…"
        case .discovering: statusText = "正在发现服务…"
        case .ready: statusText = "已连接"
        case .failed(let m): statusText = m
        }
    }

    private func describe(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "已开启"
        case .poweredOff: return "未开启"
        case .unauthorized: return "未授权"
        case .unsupported: return "不支持"
        case .resetting: return "重置中"
        default: return "未知"
        }
    }

    /// 只做格式校验，iOS 上不能用 MAC 直接连
    private static func normalizeMac(_ raw: String) -> String? {
        let plain = raw.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        return plain.count == 12 ? plain : nil
    }
}

// MARK: - 由 BLEScanner 转发的连接事件

extension BleSession {

    /// 已连接（BLEScanner 的 CBCentralManagerDelegate 转发过来）
    func handleDidConnect(_ peripheral: CBPeripheral) {
        guard canOperate, self.peripheral?.identifier == peripheral.identifier else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        setPhase(.discovering)
        AppLog.shared.i("BLE 已连接，开始发现服务")
        peripheral.discoverServices(nil)
    }

    func handleDidFailToConnect(_ error: Error?) {
        let msg = error?.localizedDescription ?? "未知原因"
        setPhase(.failed("连接失败：\(msg)"))
        AppLog.shared.w("BLE 连接失败：\(msg)")
        connectContinuation?.resume(returning: false)
        connectContinuation = nil
    }

    func handleDidDisconnect(_ error: Error?) {
        AppLog.shared.w("BLE 已断开" + (error.map { "：\($0.localizedDescription)" } ?? ""))
        if phase == .ready {
            setPhase(.failed("连接已断开"))
        }
        replyWaiters.values.forEach { $0.resume(returning: nil) }
        replyWaiters.removeAll()
    }
}


// MARK: - CBPeripheralDelegate

extension BleSession: CBPeripheralDelegate {

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.setPhase(.failed("发现服务失败：\(error.localizedDescription)"))
                self.connectContinuation?.resume(returning: false)
                self.connectContinuation = nil
                return
            }
            let services = peripheral.services ?? []
            self.gattLines.append("发现 \(services.count) 个服务")
            guard !services.isEmpty else {
                self.setPhase(.failed("连上了但没有任何 GATT 服务"))
                self.connectContinuation?.resume(returning: false)
                self.connectContinuation = nil
                return
            }
            self.servicesPending = services.count
            for s in services {
                self.gattLines.append("SERVICE \(s.uuid.uuidString)")
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            for c in service.characteristics ?? [] {
                self.gattLines.append("  CHAR \(c.uuid.uuidString)")
                if c.uuid == Self.notifyUUID {
                    self.notifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                }
                if c.uuid == Self.writeUUID {
                    self.writeChar = c
                }
            }

            self.servicesPending -= 1
            guard self.servicesPending <= 0 else { return }

            // 服务都发现完了，还需等通知真正生效
            self.checkReady()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                AppLog.shared.w("开启通知失败：\(error.localizedDescription)")
                self.setPhase(.failed("开启通知失败"))
                self.connectContinuation?.resume(returning: false)
                self.connectContinuation = nil
                return
            }
            self.notifyEnabled = true
            AppLog.shared.i("BLE 通知已生效（FF01）")
            self.checkReady()
        }
    }

    /// 两个条件都满足才算就绪
    private func checkReady() {
        guard phase == .discovering || phase == .connecting else { return }
        guard writeChar != nil else {
            setPhase(.failed("没有找到 FF02 写入特征，这台可能不是水控表"))
            connectContinuation?.resume(returning: false)
            connectContinuation = nil
            return
        }
        guard notifyEnabled || notifyChar == nil else { return }

        setPhase(.ready)
        connectContinuation?.resume(returning: true)
        connectContinuation = nil
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            self.writeContinuation?.resume(returning: error == nil)
            self.writeContinuation = nil
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        Task { @MainActor in
            self.appendAndDispatch(bytes)
        }
    }
}
