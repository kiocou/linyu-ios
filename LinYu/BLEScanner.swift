import Foundation
import CoreBluetooth
import Combine

/// 一台被扫描到的 BLE 设备。
///
/// ⚠️ 注意 `id` 是 `CBPeripheral.identifier`——**iOS 不暴露 MAC 地址**，
/// 这是系统分配的 UUID，同一台设备在不同手机上、甚至重装 App 后都可能不同。
/// 这个页面存在的意义，就是确认广播数据里有没有能替代 MAC 的识别信息。
struct DiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    /// 广播里的 Service UUID 列表
    let serviceUUIDs: [String]
    /// 厂商自定义数据（`CBAdvertisementDataManufacturerDataKey`）
    let manufacturerData: String?
    /// 服务数据（`CBAdvertisementDataServiceDataKey`）
    let serviceData: String?
    /// 是否可连接
    let isConnectable: Bool
    let lastSeen: Date

    /// 名字是否为空（连本地名都没有）
    var isUnnamed: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n == "(无名称)"
    }

    /// 看起来像不像水控设备——用于默认过滤掉耳机、手环之类。
    ///
    /// 三条判据任一命中就算：
    /// 1. 名称带厂商或品类关键词（`KLCXKJ` / `Water` / `热水` / `水表` …）
    /// 2. 广播里带厂商自定义数据（普通耳机/手环很少带）
    /// 3. 广播里带服务数据
    ///
    /// ⚠️ 这个判定**只用于默认筛选**，界面上永远可以切到「全部」——
    /// 不能因为判错就把可能的设备藏掉。
    var looksLikeWaterMeter: Bool {
        let n = name.lowercased()
        let keywords = ["klcxkj", "klcx", "water", "shower", "热水", "水表", "淋浴", "水控"]
        if keywords.contains(where: { n.contains($0) }) { return true }
        return manufacturerData != nil || serviceData != nil
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
/// 如果广播里没有任何可识别字段，那设备选择就必须改成"扫码 + 连接后读身份帧"。
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

        let manufacturer = (adv[CBAdvertisementDataManufacturerDataKey] as? Data)?
            .hexSpaced

        let serviceDataMap = adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let serviceData = serviceDataMap?.isEmpty == false
            ? serviceDataMap!
                .map { "\($0.key.uuidString): \($0.value.hexSpaced)" }
                .sorted()
                .joined(separator: "\n")
            : nil

        // RSSI == 127 是 CoreBluetooth 表示"不可用"的约定值
        let rssiValue = RSSI.intValue
        let connectable = (adv[CBAdvertisementDataIsConnectable] as? Bool) ?? false

        let item = DiscoveredPeripheral(
            id: peripheral.identifier,
            name: peripheral.name ?? localName ?? "(无名称)",
            rssi: rssiValue == 127 ? 0 : rssiValue,
            serviceUUIDs: serviceUUIDs,
            manufacturerData: manufacturer,
            serviceData: serviceData,
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
