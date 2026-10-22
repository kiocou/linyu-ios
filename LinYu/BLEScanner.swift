import Foundation
import CoreBluetooth
import Combine

/// 一台被扫描到的 BLE 设备。
///
/// ## 关于设备识别（2026-10-22 真机实测结论）
///
/// iOS 确实不暴露 `CBPeripheral` 的 MAC 地址，但这个型号的水表把 MAC
/// **直接放进了广播的 manufacturerData**，格式是：
///
/// ```
/// 00 00 | C4 7F 0E DD 2E 9C
/// └─┬─┘   └────────┬────────┘
/// CompanyID        MAC（6 字节）
/// ```
///
/// 去掉冒号就是 `snCode`（`C47F0EDD2E9C`），和 Android 端用的完全一致。
/// 实测交叉验证：`C47F0EDCBCC7` 与 2026-09-30 Android 日志里的 snCode 相同。
///
/// 另外这几台的广播 Service UUID 都是 `FEE7`，可作为"确定是凯路水表"的判据。
struct DiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    /// 广播里的 Service UUID 列表
    let serviceUUIDs: [String]
    /// 厂商自定义数据（原始字节）
    let manufacturerData: Data?
    /// 服务数据（原始字节，key 为 Service UUID）
    let serviceData: [String: Data]
    let isConnectable: Bool
    let lastSeen: Date

    // MARK: - 识别

    /// 该型号水表的广播 Service UUID（凯路）
    static let klcxkjServiceUUID = "FEE7"

    /// 广播的 Service UUID 里有没有凯路的特征服务
    var hasKlcxkjService: Bool {
        serviceUUIDs.contains { $0.uppercased() == Self.klcxkjServiceUUID }
    }

    /// 名字是否为空
    var isUnnamed: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n == "(无名称)"
    }

    /// manufacturerData 的十六进制展示
    var manufacturerHex: String? {
        manufacturerData?.hexSpaced
    }

    /// 从 manufacturerData 里解析出的 snCode。
    ///
    /// ## 严格格式校验（2026-10-22 实测后收紧）
    ///
    /// 只有**正好 8 字节**且**前两字节为 `00 00`**（Company ID == 0）的才算：
    ///
    /// ```
    /// 00 00 | C4 7F 0E DD 2E 9C
    /// ```
    ///
    /// ⚠️ 之前只判 `count >= 8` 就取最后 6 字节，结果把一堆无关设备
    /// （29 字节的、6 字节的）也「凑」出了假 snCode，实测 56 台里有 17 个假值。
    /// 宁可解析不出来，也不能给出错的 SN——错 SN 会直接导致查错台账。
    var parsedSnCode: String? {
        guard let data = manufacturerData else { return nil }
        guard data.count == 8 else { return nil }
        guard data[data.startIndex] == 0x00, data[data.startIndex + 1] == 0x00 else { return nil }
        return data.suffix(6).map { String(format: "%02X", $0) }.joined()
    }

    /// 把 snCode 还原成常见 MAC 写法（仅用于展示/对照）
    var parsedMac: String? {
        guard let sn = parsedSnCode, sn.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2)
            .map { i in
                let start = sn.index(sn.startIndex, offsetBy: i)
                let end = sn.index(start, offsetBy: 2)
                return String(sn[start..<end])
            }
            .joined(separator: ":")
    }

    /// 服务数据的十六进制展示（多个服务时换行）
    var serviceDataHex: String? {
        guard !serviceData.isEmpty else { return nil }
        return serviceData
            .map { "\($0.key): \($0.value.hexSpaced)" }
            .sorted()
            .joined(separator: "\n")
    }

    /// 看起来像不像水控设备——用于默认过滤掉耳机、手环之类。
    ///
    /// 判据（任一命中）：
    /// 1. 广播 Service UUID 含 `FEE7`（**实测 6 台真水表全部命中，最可靠**）
    /// 2. manufacturerData 是严格的 8 字节 `00 00 + MAC` 格式
    /// 3. 名称带关键词
    ///
    /// ⚠️ 不再用「有 manufacturerData 就算」——实测 56 台里 31 台都有广播数据，
    /// 里面绝大多数是耳机、手环、共享设备，那样筛等于没筛。
    ///
    /// 这个判定**只用于默认筛选**，界面上永远可以切到「全部」。
    var looksLikeWaterMeter: Bool {
        if hasKlcxkjService { return true }
        if parsedSnCode != nil { return true }
        let n = name.lowercased()
        let keywords = ["klcxkj", "klcx", "water", "shower", "热水", "水表", "淋浴", "水控"]
        return keywords.contains(where: { n.contains($0) })
    }

    /// 识别可信度，用于界面上区分"确定"和"可能"
    enum Confidence {
        case certain   // FEE7 + 能解析出 snCode
        case likely    // 只命中一项
        case unknown
    }

    var confidence: Confidence {
        if hasKlcxkjService && parsedSnCode != nil { return .certain }
        if hasKlcxkjService || parsedSnCode != nil { return .likely }
        return looksLikeWaterMeter ? .likely : .unknown
    }

    static func == (lhs: DiscoveredPeripheral, rhs: DiscoveredPeripheral) -> Bool {
        lhs.id == rhs.id
            && lhs.rssi == rhs.rssi
            && lhs.manufacturerData == rhs.manufacturerData
            && lhs.serviceData == rhs.serviceData
    }
}

/// BLE 扫描器：只做发现和展示，不连接、不写特征。
///
/// 刻意保持"只读"——这一步是为了回答一个产品问题：
/// **在 12 台同型号设备中，iOS 能不能区分出目标那一台？**
final class BLEScanner: NSObject, ObservableObject {

    @Published private(set) var devices: [DiscoveredPeripheral] = []
    @Published private(set) var stateText: String = "未开始"
    @Published private(set) var isScanning: Bool = false
    /// 累计收到多少次广播回调（用于判断"扫不到"是真没有还是回调没来）
    @Published private(set) var callbackCount: Int = 0

    private var central: CBCentralManager?
    private var byId: [UUID: DiscoveredPeripheral] = [:]
    /// 保留 `CBPeripheral` 引用——`identifier` 本身不能直接连接
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// 是否已经自动开过一次扫描——避免用户手动停止后，蓝牙状态变化又把它拉起来
    private var didAutoStart = false

    // MARK: - 连接与服务检查（只读，不发任何命令）

    /// 当前正在连接/已连接设备的 identifier
    @Published private(set) var connectedId: UUID?
    /// GATT 发现的逐行日志
    @Published private(set) var gattLog: [String] = []
    /// 一句话结论（有没有 FF00）
    @Published private(set) var gattSummary: String = ""
    /// 还有多少个服务的特征没发现完（归零时做判定）
    private var servicesPending = 0

    /// 该项目依赖的水控 GATT 服务与特征
    static let serviceFF00 = "FF00"
    static let notifyFF01 = "FF01"
    static let writeFF02 = "FF02"

    /// 连接设备并发现服务。**只读，不写任何特征。**
    func connect(_ id: UUID) {
        guard let central, let p = peripherals[id] else {
            gattSummary = "找不到该设备的引用（请重新扫描）"
            return
        }
        if isScanning {
            central.stopScan()
            isScanning = false
            stateText = "已暂停扫描（正在连接）"
        }
        gattLog.removeAll()
        gattSummary = "正在连接 \(p.name ?? id.uuidString.prefix(8))…"
        connectedId = id
        p.delegate = self
        central.connect(p, options: nil)
    }

    func disconnect() {
        guard let central, let id = connectedId, let p = peripherals[id] else { return }
        central.cancelPeripheralConnection(p)
        connectedId = nil
        gattSummary = "已断开"
    }

    /// 某台设备是否正在连接/已连接
    func isConnected(_ id: UUID) -> Bool { connectedId == id }

    override init() {
        super.init()
        // 构造时就建 manager，系统会在需要时弹蓝牙权限
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        devices.removeAll()
        byId.removeAll()
        callbackCount = 0

        guard let central else { return }
        if central.state == .poweredOn {
            beginScan(central)
        } else {
            stateText = "等待蓝牙就绪（当前：\(describe(central.state))）"
        }
    }

    func stop() {
        guard let central, central.state == .poweredOn else {
            isScanning = false
            return
        }
        central.stopScan()
        isScanning = false
        stateText = "已停止（本次扫到 \(devices.count) 台）"
    }

    // MARK: - 私有

    private func beginScan(_ central: CBCentralManager) {
        // 允许重复回调：否则同一台设备只会出现一次，RSSI 不会更新
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
        stateText = "正在扫描…"
    }

    private func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn:   return "已开启"
        case .poweredOff:  return "未开启"
        case .unauthorized: return "未授权"
        case .unsupported: return "不支持"
        case .resetting:   return "重置中"
        case .unknown:     return "未知"
        @unknown default:  return "未知"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEScanner: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateText = describe(central.state)
        // 进页面自动扫一次：这个页面的用途就是"到了澡堂立刻看数据"，
        // 多一步点击反而容易让人忘了点。只自动一次，之后完全由用户控制。
        if central.state == .poweredOn && !didAutoStart {
            didAutoStart = true
            beginScan(central)
        }
    }

    // MARK: 连接回调（只发现服务，不发命令）

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        gattSummary = "已连接，正在发现服务…"
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        gattSummary = "❌ 连接失败：\(error?.localizedDescription ?? "未知原因")"
        connectedId = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if connectedId != nil {
            gattSummary = "已断开\(error.map { "（\($0.localizedDescription)）" } ?? "")"
        }
        connectedId = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {        callbackCount += 1

        let adv = advertisementData
        let localName = adv[CBAdvertisementDataLocalNameKey] as? String
        let serviceUUIDs = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString) ?? []

        let manufacturer = adv[CBAdvertisementDataManufacturerDataKey] as? Data

        var serviceDataMap: [String: Data] = [:]
        if let raw = adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (k, v) in raw { serviceDataMap[k.uuidString] = v }
        }

        // RSSI == 127 是 CoreBluetooth 表示"不可用"的约定值
        let rssiValue = RSSI.intValue
        let connectable = (adv[CBAdvertisementDataIsConnectable] as? Bool) ?? false

        let item = DiscoveredPeripheral(
            id: peripheral.identifier,
            name: peripheral.name ?? localName ?? "(无名称)",
            rssi: rssiValue == 127 ? 0 : rssiValue,
            serviceUUIDs: serviceUUIDs,
            manufacturerData: manufacturer,
            serviceData: serviceDataMap,
            isConnectable: connectable,
            lastSeen: Date()
        )

        byId[item.id] = item
        // 保留引用，后面"连接测试"要用
        peripherals[item.id] = peripheral
        devices = byId.values.sorted { $0.rssi > $1.rssi }
    }
}

// MARK: - CBPeripheralDelegate（只发现，不读写）

extension BLEScanner: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            gattSummary = "发现服务失败：\(error.localizedDescription)"
            return
        }
        let services = peripheral.services ?? []
        gattLog.append("发现 \(services.count) 个服务")
        guard !services.isEmpty else {
            gattSummary = "❌ 连上了，但没有任何 GATT 服务"
            return
        }
        servicesPending = services.count
        for s in services {
            gattLog.append("SERVICE \(s.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            gattLog.append("  ⚠️ \(service.uuid.uuidString) 特征发现失败：\(error.localizedDescription)")
        } else {
            for c in service.characteristics ?? [] {
                gattLog.append("  CHAR \(c.uuid.uuidString) [\(Self.describe(c.properties))]")
            }
        }
        servicesPending -= 1
        if servicesPending <= 0 {
            evaluate(peripheral)
        }
    }

    /// 根据已发现的服务，给出「iOS 能不能走通水控协议」的结论
    private func evaluate(_ peripheral: CBPeripheral) {
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            gattSummary = "❌ 连上了，但没有任何 GATT 服务"
            return
        }

        var found: Set<String> = []
        for s in services {
            if let short = Self.shortUUID(s.uuid) { found.insert(short) }
            for c in s.characteristics ?? [] {
                if let short = Self.shortUUID(c.uuid) { found.insert(short) }
            }
        }

        let hasFF00 = found.contains(Self.serviceFF00)
        let hasFF01 = found.contains(Self.notifyFF01)
        let hasFF02 = found.contains(Self.writeFF02)

        gattLog.append("")
        gattLog.append("识别到 16-bit UUID：\(found.sorted().joined(separator: ", "))")

        if hasFF00 && hasFF01 && hasFF02 {
            gattSummary = "✅ 找到 FF00 / FF01 / FF02 —— iOS 可以完整走通水控协议"
        } else if hasFF00 {
            gattSummary = "⚠️ 有 FF00，但缺 FF01(\(hasFF01 ? "有" : "无")) / FF02(\(hasFF02 ? "有" : "无"))"
        } else {
            gattSummary = "❌ 没有 FF00 服务（共 \(services.count) 个服务，\(found.count) 个 16-bit UUID）"
        }
    }

    /// 把 CBUUID 转成 16-bit 短格式（如 `FF00`）。
    ///
    /// ⚠️ 不能直接 `suffix(4)`：完整 UUID `0000FF00-0000-1000-8000-00805F9B34FB`
    /// 的后 4 位是 `34FB`，短 UUID 在**第 5–8 位**。
    static func shortUUID(_ uuid: CBUUID) -> String? {
        let s = uuid.uuidString.uppercased()
        if s.count == 4 { return s }
        if s.count == 36, s.hasPrefix("0000") {
            let start = s.index(s.startIndex, offsetBy: 4)
            let end = s.index(start, offsetBy: 4)
            return String(s[start..<end])
        }
        return nil
    }

    static func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.isEmpty ? "无" : parts.joined(separator: ",")
    }
}

// MARK: - 工具

extension Data {
    /// 每字节两位大写十六进制，空格分隔——方便和 Android 日志里的抓帧对比
    var hexSpaced: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
