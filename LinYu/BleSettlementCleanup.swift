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
        let state = await readState()
        guard isCurrent(), !Task.isCancelled else { return false }
        // 0x86 的 ACK 不能代替状态回读；未知、仍有遗留记录均不算已清理。
        return state == 0
    }
}
