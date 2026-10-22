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
    /// 规则：跳过前 2 字节 Company ID，取后面 6 字节 MAC，转成 12 位大写 hex。
    /// 不足 8 字节时返回 nil（不做猜测）。
    var parsedSnCode: String? {
        guard let data = manufacturerData, data.count >= 8 else { return nil }
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
    /// 优先级从高到低：
    /// 1. 广播 Service UUID 含 `FEE7`（**最可靠**，实测确认）
    /// 2. 能从 manufacturerData 解析出 snCode
    /// 3. 名称带关键词
    /// 4. 带任意 manufacturerData / serviceData
    ///
    /// ⚠️ 这个判定**只用于默认筛选**，界面上永远可以切到「全部」。
    var looksLikeWaterMeter: Bool {
        if hasKlcxkjService { return true }
        if parsedSnCode != nil { return true }
        let n = name.lowercased()
        let keywords = ["klcxkj", "klcx", "water", "shower", "热水", "水表", "淋浴", "水控"]
        if keywords.contains(where: { n.contains($0) }) { return true }
        return manufacturerData != nil || !serviceData.isEmpty
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
    /// 是否已经自动开过一次扫描——避免用户手动停止后，蓝牙状态变化又把它拉起来
    private var didAutoStart = false

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

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        callbackCount += 1

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
        devices = byId.values.sorted { $0.rssi > $1.rssi }
    }
}

// MARK: - 工具

extension Data {
    /// 每字节两位大写十六进制，空格分隔——方便和 Android 日志里的抓帧对比
    var hexSpaced: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
