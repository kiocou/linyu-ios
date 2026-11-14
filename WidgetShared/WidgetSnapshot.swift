import Foundation

struct WidgetDevice: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var detail: String
    var emoji: String
    var rssi: Int?
    var running = false
    var occupied = false
    var orderNo = ""
    var startedAt: Int64 = 0
    var preDeduct: Double = 0
    var lastConsume: Double = 0
    var selectable = true
    /// 只收录台账已确认属于此 SN 的地址，不能用猜测地址合并设备。
    var aliases: [String]? = nil
}

struct WidgetBill: Codable, Equatable {
    var name: String
    var emoji: String
    var time: String
    var money: String
    var id: String? = nil
    var deviceSN: String? = nil
    var detail: String? = nil
    var amount: Double? = nil
}

struct WidgetSnapshot: Codable, Equatable {
    var owner = ""
    var token = UUID().uuidString
    var date = Date()
    var nearbyDate: Date?
    var lastDevice = ""
    var devices: [WidgetDevice] = []
    var nearbyIDs: [String] = []
    var bills: [WidgetBill] = []
    var balance = "¥ —"
    var balanceTitle = "余额"
    var message: String?
    var busy = false

    var emptyTitle: String { message == nil ? "未登录" : "等待同步" }

    func selected(_ id: String) -> WidgetDevice? {
        let chosen = id.isEmpty ? lastDevice : id
        return devices.first { ($0.id == chosen || $0.aliases?.contains(chosen) == true) && ($0.selectable || $0.running) }
    }
    /// 展示可回退；具体按钮仍绑定实际渲染的设备，不把旧控制链接改投另一台。
    func displayedDevice(_ preferredID: String) -> WidgetDevice? {
        let last = selected("")
        if last?.running == true { return last }
        if let preferred = selected(preferredID) { return preferred }
        if let last { return last }
        // 只有一台正在使用时保留停止入口，多台时不擅自挑选。
        let running = devices.filter(\.running)
        return running.count == 1 ? running[0] : nil
    }
    /// 状态转换时使旧按钮失效；金额和信号刷新不作废按钮。
    var controlIdentity: String {
        owner + "|" + devices.sorted { $0.id < $1.id }.map {
            "\($0.id):\($0.running):\($0.orderNo):\($0.startedAt):\($0.selectable)"
        }.joined(separator: "|")
    }
}

enum WidgetDisplayPolicy {
    // Android 按设备保存消费；没有本机记录时，只用明确匹配设备的账单补齐。
    static func lastConsume(cached: Double, device: WidgetDevice, bills: [WidgetBill]) -> Double {
        if cached > 0 { return cached }
        return bills.first(where: {
            guard ($0.amount ?? 0) > 0 else { return false }
            if let sn = $0.deviceSN, !sn.isEmpty { return sn == device.id || device.aliases?.contains(sn) == true }
            return !device.name.isEmpty && $0.name == device.name && $0.detail == device.detail
        })?.amount ?? 0
    }
    static func syncedAgo(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        return "\(minutes / 60) 小时前"
    }
}

enum WidgetCommandKind: String, Codable { case start, stop, refresh, home, bills, nearby, device, billDetail, refreshNearby }
extension WidgetCommandKind {
    var isNavigation: Bool {
        switch self {
        case .home, .bills, .nearby, .device, .billDetail: return true
        default: return false
        }
    }
}
struct WidgetCommand: Equatable, Identifiable {
    let id = UUID()
    let kind: WidgetCommandKind
    let owner: String
    let sn: String
    let orderNo: String
    let startedAt: Int64
    let token: String
    let billID: String

    static func url(_ kind: WidgetCommandKind, snapshot: WidgetSnapshot, device: WidgetDevice?, billID: String = "") -> URL {
        var parts = URLComponents()
        parts.scheme = "linyu-widget"
        parts.host = kind.rawValue
        parts.queryItems = [URLQueryItem(name: "owner", value: snapshot.owner),
                           URLQueryItem(name: "token", value: snapshot.token),
                           URLQueryItem(name: "sn", value: device?.id ?? ""),
                           URLQueryItem(name: "order", value: device?.orderNo ?? ""),
                           URLQueryItem(name: "start", value: String(device?.startedAt ?? 0))]
        if !billID.isEmpty { parts.queryItems?.append(URLQueryItem(name: "bill", value: billID)) }
        return parts.url!
    }
    init?(url: URL) {
        guard url.scheme == "linyu-widget", let kind = WidgetCommandKind(rawValue: url.host ?? ""),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = parts.queryItems ?? []
        func field(_ key: String) -> String { items.first { $0.name == key }?.value ?? "" }
        let keys = Set(items.map(\.name))
        guard keys == Set(["owner", "token", "sn", "order", "start"]) || keys == Set(["owner", "token", "sn", "order", "start", "bill"]),
              items.count == keys.count,
              let start = Int64(field("start")) else { return nil }
        self.kind = kind; owner = field("owner"); sn = field("sn")
        orderNo = field("order"); startedAt = start; token = field("token")
        billID = field("bill")
    }
    func matches(_ snapshot: WidgetSnapshot) -> Bool {
        guard !owner.isEmpty, owner == snapshot.owner, token == snapshot.token else { return false }
        if kind != .start && kind != .stop { return true }
        guard let device = snapshot.devices.first(where: { $0.id == sn }), device.selectable || device.running else { return false }
        // 旧开启入口允许恢复同设备已有订单；关闭始终严格绑定原订单。
        return kind == .start ? !device.occupied : device.running && device.orderNo == orderNo && device.startedAt == startedAt
    }

    var deliveryKey: String {
        [kind.rawValue, owner, token, sn, orderNo, String(startedAt), billID].joined(separator: "|")
    }
}

/// 同一次桌面点击可能经系统重复交付；普通首页入口不能抢占尚未执行的开关动作。
struct WidgetDeliveryPolicy {
    private var lastKey = ""
    private var lastReceived = Date.distantPast
    private var navigationKeys: Set<String> = []

    mutating func enteredBackground() { navigationKeys.removeAll() }

    mutating func accept(_ request: WidgetCommand, pending: WidgetCommand?, handling: Bool, now: Date = Date()) -> Bool {
        guard !handling else { return false }
        if let pending, !pending.kind.isNavigation { return false }
        if request.kind.isNavigation, navigationKeys.contains(request.deliveryKey) { return false }
        guard request.deliveryKey != lastKey || now.timeIntervalSince(lastReceived) >= 1 else { return false }
        lastKey = request.deliveryKey
        lastReceived = now
        if request.kind.isNavigation { navigationKeys.insert(request.deliveryKey) }
        return true
    }
}

enum WidgetGroupPolicy {
    /// SideStore 会为组名追加签名团队后缀；只读取本 bundle 的配置，不遍历其他应用。
    static func candidates(profile: Data?, original: String) -> [String] {
        guard let profile, profile.count < 2_000_000,
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let root = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [original] }
        let matching = groups.filter { $0 == original || $0.hasPrefix(original + ".") }
        return matching.isEmpty ? [original] : matching
    }
}

enum WidgetSharedStore {
    static let group = "group.com.hualala.linyu"
    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }
    private static var resolvedDirectory: URL?
    static var directory: URL? {
        // 成功后复用地址，不在每次切页反复解析签名描述文件；失败不永久缓存。
        if let resolvedDirectory { return resolvedDirectory }
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        for identifier in WidgetGroupPolicy.candidates(profile: profile, original: group) {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
                resolvedDirectory = url
                return url
            }
        }
        return nil
    }
    static func read() -> WidgetSnapshot {
        guard let url = directory?.appendingPathComponent("widget-snapshot.json"),
              let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            var empty = WidgetSnapshot()
            empty.message = directory == nil ? "小组件无法同步，请检查安装权限" : "请先打开淋浴"
            return empty
        }
        return snapshot
    }
    @discardableResult static func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url = directory?.appendingPathComponent("widget-snapshot.json"), let data = try? JSONEncoder().encode(snapshot) else { return false }
        do { try data.write(to: url, options: writeOptions); return true }
        catch { return false }
    }
    struct Selection: Codable { var owner = ""; var device = ""; var tab = 0 }
    static func selection(_ slot: String, owner: String? = nil) -> Selection {
        guard let url = selectionURL(slot), let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Selection.self, from: data), value.owner == (owner ?? read().owner) else { return Selection() }
        return value
    }
    static func select(_ value: Selection, slot: String) {
        guard let url = selectionURL(slot), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: writeOptions)
    }
    static func followLastDevice(owner: String) {
        for slot in ["1", "2", "3", "4"] {
            var value = selection(slot, owner: owner)
            value.owner = owner
            value.device = ""
            select(value, slot: slot)
        }
    }
    private static func selectionURL(_ slot: String) -> URL? {
        guard ["1", "2", "3", "4"].contains(slot) else { return nil }
        return directory?.appendingPathComponent("widget-selection-\(slot).json")
    }
}
