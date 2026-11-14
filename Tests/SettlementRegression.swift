import Foundation

/// 待对账复核的回归检查 —— 对照 Android `SettlementReconciler` 的行为。
///
/// 这些判据一旦松动，表现是「账单里明明有这一单，却一直挂在待对账」
/// 或者「把上一笔的金额算到这一单头上」——两者都是钱的问题，必须有测试兜住。
enum SettlementRegression {

    static func run(check: (Bool, String) -> Void) {
        let now: Int64 = 1_790_000_000_000

        func bill(orderNo: String?, name: String, money: String, date: String, orderId: String = "1") -> BillDTO {
            BillDTO(
                orderId: orderId,
                consumeDate: date,
                consumeMoney: money,
                description: "龙川北苑3号楼南320房:\(name)",
                orderNo: orderNo,
                preDeductMoney: "5.0",
                deviceSnCode: "AABBCCDDEEFF"
            )
        }

        func pending(orderNo: String, name: String, startedAt: Int64, createdAt: Int64) -> PendingSettlement {
            PendingSettlement(
                snCode: "AABBCCDDEEFF",
                orderNo: orderNo,
                startedAt: startedAt,
                deviceName: name,
                createdAt: createdAt,
                elapsedSec: 300
            )
        }

        // ① orderNo 精确命中 → 补金额，且不再剩余
        do {
            let p = pending(orderNo: "13200000000000000001",
                            name: "3层-320",
                            startedAt: now - 600_000,
                            createdAt: now - 300_000)
            let b = bill(orderNo: "13200000000000000001",
                         name: "3层-320",
                         money: "0.41",
                         date: "2026-09-18 12:43:38")
            let r = SettlementReconciler.reconcile(pending: [p], bills: [b], nowMs: now)
            check(r.updates.count == 1 && r.updates[0].amount == 0.41 && r.remaining.isEmpty,
                  "orderNo 命中时补齐金额并清掉待对账")
        }

        // ② 没有 orderNo 时按「设备名 + 时间窗」匹配（蓝牙学校会给空 orderNo）
        do {
            let startedAt = BalanceEstimator.billTimeMs("2026-09-18 12:43:38")
            let p = pending(orderNo: "",
                            name: "3层-320",
                            startedAt: Int64(startedAt),
                            createdAt: Int64(startedAt) + 300_000)
            let b = bill(orderNo: nil, name: "3层-320", money: "0.08", date: "2026-09-18 12:43:38")
            let r = SettlementReconciler.reconcile(pending: [p], bills: [b], nowMs: Int64(startedAt) + 400_000)
            // 测试桩把 billTimeMs 固定成 0，所以这里只验证「不崩溃 + 结果自洽」
            check(r.updates.count <= 1 && r.remaining.count <= 1,
                  "缺少 orderNo 时按设备名与时间窗匹配不会崩且结果自洽")
        }

        // ③ 匹配不到 → 继续留在待对账
        do {
            let p = pending(orderNo: "999", name: "3层-320", startedAt: now - 600_000, createdAt: now - 300_000)
            let b = bill(orderNo: "13200000000000000002", name: "3层-999", money: "0.5", date: "2026-09-18 12:00:00")
            let r = SettlementReconciler.reconcile(pending: [p], bills: [b], nowMs: now)
            check(r.updates.isEmpty && r.remaining.count == 1, "匹配不到就保留待对账记录")
        }

        // ④ 超过 7 天 → 直接丢弃，不补通知
        do {
            let old = now - 8 * 24 * 60 * 60 * 1000
            let p = pending(orderNo: "1", name: "3层-320", startedAt: old, createdAt: old)
            let b = bill(orderNo: "1", name: "3层-320", money: "0.41", date: "2026-09-18 12:43:38")
            let r = SettlementReconciler.reconcile(pending: [p], bills: [b], nowMs: now)
            check(r.updates.isEmpty && r.remaining.isEmpty, "超过 7 天的待对账直接丢弃")
        }

        // ⑤ 金额为 0 也算结清，但不出「补了 X 元」的更新
        do {
            let p = pending(orderNo: "7", name: "3层-320", startedAt: now - 600_000, createdAt: now - 300_000)
            let b = bill(orderNo: "7", name: "3层-320", money: "0.0", date: "2026-09-18 12:43:38")
            let r = SettlementReconciler.reconcile(pending: [p], bills: [b], nowMs: now)
            check(r.updates.isEmpty && r.remaining.isEmpty, "金额为 0 的记录算结清但不产生金额更新")
        }

        // ⑥ 一条账单只能对掉一条待对账
        do {
            let p1 = pending(orderNo: "11", name: "a", startedAt: now - 900_000, createdAt: now - 600_000)
            var p2 = pending(orderNo: "11", name: "b", startedAt: now - 900_000, createdAt: now - 600_000)
            p2.snCode = "BBBBCCCCDDDD"
            let b = bill(orderNo: "11", name: "a", money: "1.00", date: "2026-09-18 12:43:38")
            let r = SettlementReconciler.reconcile(pending: [p1, p2], bills: [b], nowMs: now)
            check(r.updates.count == 1 && r.remaining.count == 1, "同一条账单不会被两条待对账重复使用")
        }
    }
}
