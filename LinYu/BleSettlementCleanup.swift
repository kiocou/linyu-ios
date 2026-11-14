import Foundation

/// 记账与设备清理是两个结果；清理失败不能把已记账订单上报作废。
struct BleSettlementResult {
    let uploadAccepted: Bool
    let recordCleared: Bool
    let amount: Double?
    static let failed = BleSettlementResult(uploadAccepted: false, recordCleared: false, amount: nil)
}

enum BleSettlementCleanup {
    @MainActor
    static func confirm(isCurrent: () -> Bool, writeBack: () async -> Void,
                        readState: () async -> Int?) async -> Bool {
        guard isCurrent(), !Task.isCancelled else { return false }
        await writeBack()
        guard isCurrent(), !Task.isCancelled else { return false }
        // 0x86 的 ACK 不能代替状态回读；但设备落盘有几十~几百毫秒延迟，
        // 只读一次就判失败会造成「账单已结清、设备清理未确认」的死循环
        // （2026-11-14 22:54 真机：0x86 刚发完就回读，读到 state=6 被判未清）。
        for attempt in 0 ..< 3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard isCurrent(), !Task.isCancelled else { return false }
            }
            if let state = await readState(), state == 0 { return true }
        }
        return false
    }
}
