import Foundation

enum BleSettlementRegression {
    @MainActor
    static func run(check: (Bool, String) -> Void) async {
        for state: Int? in [1, 3, 6, nil] {
            let cleared = await BleSettlementCleanup.confirm(isCurrent: { true }, writeBack: {}, readState: { state })
            check(!cleared, "写回 ACK 不代替空闲确认：\(String(describing: state))")
        }
        var calls: [String] = []
        let cleared = await BleSettlementCleanup.confirm(isCurrent: { true },
            writeBack: { calls.append("write") }, readState: { calls.append("query"); return 0 })
        check(cleared && calls == ["write", "query"], "写回后再查询，空闲才确认清理")
        let lostAck = await BleSettlementCleanup.confirm(isCurrent: { true }, writeBack: {}, readState: { 0 })
        check(lostAck, "ACK 丢失或无清理包时仍可凭空闲状态确认")
        var current = true
        var queried = false
        let switched = await BleSettlementCleanup.confirm(isCurrent: { current },
            writeBack: { current = false }, readState: { queried = true; return 0 })
        check(!switched && !queried, "会话切换后不查询另一账户设备")
        current = true
        let late = await BleSettlementCleanup.confirm(isCurrent: { current },
            writeBack: {}, readState: { current = false; return 0 })
        check(!late, "会话过期后的旧查询不能确认清理")
        var written = false
        let invalid = await BleSettlementCleanup.confirm(isCurrent: { false },
            writeBack: { written = true }, readState: { 0 })
        check(!invalid && !written, "失效会话不写设备")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await BleSettlementCleanup.confirm(isCurrent: { true },
                writeBack: { written = true }, readState: { 0 })
        }
        let cancelled = await task.value
        check(!cancelled && !written, "取消任务不继续设备写回")
        let accepted = BleSettlementResult(uploadAccepted: true, recordCleared: false, amount: 1.84)
        check(accepted.uploadAccepted && !accepted.recordCleared && accepted.amount == 1.84,
              "清理未确认保留记账与金额，不进入失败上报")
        check(!BleSettlementResult.failed.uploadAccepted && BleSettlementResult.failed.amount == nil,
              "未上传成功不冒充已记账")
    }
}
