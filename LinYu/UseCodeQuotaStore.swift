import Foundation

enum UseCodeQuotaStore {
    struct Record: Codable { let remaining: Int; let date: Date }
    static func read(owner: String, defaults: UserDefaults = .standard, now: Date = Date()) -> Record? {
        guard !owner.isEmpty, let data = defaults.data(forKey: "useCodeQuota_" + owner),
              let value = try? JSONDecoder().decode(Record.self, from: data),
              Calendar.current.isDate(value.date, inSameDayAs: now) else { return nil }
        return value
    }
    static func save(owner: String, remaining: Int, defaults: UserDefaults = .standard, now: Date = Date()) {
        guard !owner.isEmpty, let data = try? JSONEncoder().encode(Record(remaining: max(0, remaining), date: now)) else { return }
        defaults.set(data, forKey: "useCodeQuota_" + owner)
    }
}
