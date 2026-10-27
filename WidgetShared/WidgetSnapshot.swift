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
}

struct WidgetBill: Codable, Equatable {
    var name: String
    var emoji: String
    var time: String
    var money: String
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

    func selected(_ id: String) -> WidgetDevice? {
        let chosen = id.isEmpty ? lastDevice : id
        return devices.first { $0.id == chosen && ($0.selectable || $0.running) }
    }
    /// 状态转换时使旧按钮失效；金额和信号刷新不作废按钮。
    var controlIdentity: String {
        owner + "|" + devices.sorted { $0.id < $1.id }.map {
            "\($0.id):\($0.running):\($0.orderNo):\($0.startedAt):\($0.selectable)"
        }.joined(separator: "|")
    }
}

enum WidgetCommandKind: String, Codable { case start, stop, refresh, home, bills, nearby }
struct WidgetCommand: Equatable, Identifiable {
    let id = UUID()
    let kind: WidgetCommandKind
    let owner: String
    let sn: String
    let orderNo: String
    let startedAt: Int64
    let token: String

    static func url(_ kind: WidgetCommandKind, snapshot: WidgetSnapshot, device: WidgetDevice?) -> URL {
        var parts = URLComponents()
        parts.scheme = "linyu-widget"
        parts.host = kind.rawValue
        parts.queryItems = [URLQueryItem(name: "owner", value: snapshot.owner),
                           URLQueryItem(name: "token", value: snapshot.token),
                           URLQueryItem(name: "sn", value: device?.id ?? ""),
                           URLQueryItem(name: "order", value: device?.orderNo ?? ""),
                           URLQueryItem(name: "start", value: String(device?.startedAt ?? 0))]
        return parts.url!
    }
    init?(url: URL) {
        guard url.scheme == "linyu-widget", let kind = WidgetCommandKind(rawValue: url.host ?? ""),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = parts.queryItems ?? []
        func field(_ key: String) -> String { items.first { $0.name == key }?.value ?? "" }
        guard items.count == 5, Set(items.map(\.name)).count == 5,
              let start = Int64(field("start")) else { return nil }
        self.kind = kind; owner = field("owner"); sn = field("sn")
        orderNo = field("order"); startedAt = start; token = field("token")
    }
    func matches(_ snapshot: WidgetSnapshot) -> Bool {
        guard !owner.isEmpty, owner == snapshot.owner, token == snapshot.token else { return false }
        if kind != .start && kind != .stop { return true }
        guard let device = snapshot.devices.first(where: { $0.id == sn }), device.selectable || device.running else { return false }
        return kind == .start ? !device.running : device.running && device.orderNo == orderNo && device.startedAt == startedAt
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
    static let directory: URL? = {
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        for identifier in WidgetGroupPolicy.candidates(profile: profile, original: group) {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) { return url }
        }
        return nil
    }()
    static func read() -> WidgetSnapshot {
        guard let url = directory?.appendingPathComponent("widget-snapshot.json"),
              let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            var empty = WidgetSnapshot()
            empty.message = directory == nil ? "请保留小组件扩展和共享权限" : "请先打开淋浴"
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
    static func selection(_ slot: String) -> Selection {
        guard let url = selectionURL(slot), let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Selection.self, from: data), value.owner == read().owner else { return Selection() }
        return value
    }
    static func select(_ value: Selection, slot: String) {
        guard let url = selectionURL(slot), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: writeOptions)
    }
    private static func selectionURL(_ slot: String) -> URL? {
        guard ["1", "2", "3", "4"].contains(slot) else { return nil }
        return directory?.appendingPathComponent("widget-selection-\(slot).json")
    }
}
