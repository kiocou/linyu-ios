import Foundation

/// Android BillHistoryCache：账号独立快照，仅完整刷新成功时覆盖。
enum BillHistoryCache {
    private static func key(_ owner: String) -> String { "billCache_" + owner }
    static func read(owner: String, defaults: UserDefaults = .standard) -> [BillDTO]? {
        guard !owner.isEmpty, let data = defaults.data(forKey: key(owner)) else { return nil }
        return try? JSONDecoder().decode([BillDTO].self, from: data)
    }
    static func save(_ bills: [BillDTO], owner: String, defaults: UserDefaults = .standard) {
        guard !owner.isEmpty, let data = try? JSONEncoder().encode(bills) else { return }
        defaults.set(data, forKey: key(owner))
    }
}
