import Foundation

/// 一条「金额还没落定」的待对账记录 —— 对照 Android 的 `data/PendingSettlement.kt`。
///
/// ## 什么时候会登记
///
/// 结算查询返回「不知道」（`nil`），或者「接口说 0、但账单列表里从没出现过这一单」
/// （这是**推断**出来的零消费，不是直接证据）。这两种情况都不能就这么算了：
/// 服务端稍后可能把金额补上，而用户已经关了水、界面也退了。
///
/// 所以登记一条，等下次拿到账单列表时复核：复核到就补金额，复核不到就维持原判。
struct PendingSettlement: Codable, Equatable {
    var snCode: String
    var orderNo: String
    /// 开阀时间（毫秒时间戳）
    var startedAt: Int64
    var deviceName: String
    /// 登记时刻（毫秒时间戳）
    var createdAt: Int64
    /// 用水时长（秒），登记时就定下来。
    ///
    /// 事后对账补通知时已经拿不到准确的结束时刻了（服务早收工、界面也退了），
    /// 不存一份的话，补发的通知只能写「消费 ¥x.xx」而写不出用时。
    var elapsedSec: Int = 0
}

struct SettlementUpdate: Equatable {
    let snCode: String
    let amount: Double
}

struct SettlementReconciliation: Equatable {
    var updates: [SettlementUpdate] = []
    var remaining: [PendingSettlement] = []
}

/// 待对账记录的读写 —— 对照 Android `PrefsHelper.getPendingSettlements` 等四个方法
enum PendingSettlementStore {

    private static let key = "pendingSettlements"
    private static let lock = NSRecursiveLock()

    static func all() -> [PendingSettlement] {
        lock.lock(); defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingSettlement].self, from: data)) ?? []
    }

    static func save(_ items: [PendingSettlement]) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// 登记一条；同 snCode 的旧记录直接被替换（一台设备同时只可能有一单）
    static func record(_ item: PendingSettlement) {
        lock.lock(); defer { lock.unlock() }
        var items = all().filter { $0.snCode != item.snCode }
        items.append(item)
        save(items)
    }

    static func clear(snCode: String) {
        lock.lock(); defer { lock.unlock() }
        save(all().filter { $0.snCode != snCode })
    }

    static func clearAll() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 拿账单列表复核待对账记录 —— 逐条对照 Android 的 `SettlementReconciler`。
///
/// ## 两条匹配规则，按可信度排序
///
/// 1. **orderNo 精确命中**：唯一可靠，优先用
/// 2. **设备名 + 时间窗**：orderNo 为空时才退到这里（蓝牙那几所学校会给空 orderNo）
///
/// 时间窗以「开阀时刻」为基准，前后各留 3 分钟。账单里的时间是**下单那一刻**，
/// 比本地 startedAt（开阀确认成功）早 1~2 秒，所以窗口必须往前放宽。
enum SettlementReconciler {

    /// 超过 7 天的记录直接丢弃：订单早就结算完了，再对账只是白白多发一条通知
    static let maxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000
    static let timeSlackMs: Int64 = 3 * 60 * 1000

    static func reconcile(
        pending: [PendingSettlement],
        bills: [BillDTO],
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> SettlementReconciliation {
        var available = bills
        var updates: [SettlementUpdate] = []
        var remaining: [PendingSettlement] = []

        for item in pending {
            if nowMs - item.createdAt > maxAgeMs { continue }

            let matched: BillDTO?
            if !item.orderNo.trimmingCharacters(in: .whitespaces).isEmpty {
                matched = available.first { $0.orderNo == item.orderNo }
            } else {
                let candidates = available.filter { bill in
                    let billTime = Int64(BalanceEstimator.billTimeMs(bill.consumeDate ?? ""))
                    return !item.deviceName.isEmpty &&
                        bill.displayNamePart == item.deviceName &&
                        billTime >= item.startedAt - timeSlackMs &&
                        billTime <= item.createdAt + timeSlackMs
                }
                matched = candidates.min { a, b in
                    let ta = BalanceEstimator.billTimeMs(a.consumeDate ?? "")
                    let tb = BalanceEstimator.billTimeMs(b.consumeDate ?? "")
                    return abs(ta - Double(item.startedAt)) < abs(tb - Double(item.startedAt))
                }
            }

            guard let matched, let amount = matched.yuan, amount.isFinite, amount >= 0 else {
                remaining.append(item)
                continue
            }

            if let i = available.firstIndex(where: { $0.id == matched.id }) {
                available.remove(at: i)
            }
            // 金额 0 就不发「补了 X 元」的通知了，但这条记录照样算结清
            if amount > 0 {
                updates.append(SettlementUpdate(snCode: item.snCode, amount: amount))
            }
        }

        return SettlementReconciliation(updates: updates, remaining: remaining)
    }
}
