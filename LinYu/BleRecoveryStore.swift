import Foundation

/// Android BleShowerController.Session 的恢复字段；不持久化凭证或费率包。
struct BleRecoveryRecord: Codable {
    let owner: String
    let snCode: String
    let orderNo: String
    let startedAt: Int64
    let protocolType: String
    let randomNumber: String
    let consumeDate: String
}
enum BleRecoveryStore {
    private static let key = "bleSessionJson"
    private static func all(_ defaults: UserDefaults) -> [BleRecoveryRecord] {
        guard let text = defaults.string(forKey: key), let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([BleRecoveryRecord].self, from: data)) ?? []
    }
    static func read(owner: String, snCode: String, orderNo: String, startedAt: Int64,
                     defaults: UserDefaults = .standard) -> BleRecoveryRecord? {
        guard !owner.isEmpty, startedAt > 0 else { return nil }
        return all(defaults).first {
            $0.owner == owner && $0.snCode == snCode && $0.startedAt == startedAt &&
                ($0.orderNo == orderNo || $0.orderNo.isEmpty || orderNo.isEmpty)
        }
    }
    static func save(_ value: BleRecoveryRecord, defaults: UserDefaults = .standard) {
        var values = all(defaults).filter { $0.owner == value.owner && $0.snCode != value.snCode }
        values.append(value)
        write(values, defaults)
    }
    static func remove(snCode: String, defaults: UserDefaults = .standard) {
        write(all(defaults).filter { $0.snCode != snCode }, defaults)
    }
    private static func write(_ values: [BleRecoveryRecord], _ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: key)
    }
}
