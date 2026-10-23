import Foundation

/// 纯逻辑层的回归检查 —— 不依赖 UI、不依赖网络。
///
/// 覆盖两处最容易**静默出错**的地方：
/// 1. 结算金额的解析（错 1000 倍不报错，只是数字看着还挺正常）
/// 2. 活跃订单的原子读改写（并发写回会整份覆盖，订单凭空消失）
enum CoreLogicRegression {

    static func run(check: (Bool, String) -> Void) {
        settleProbe(check: check)
        activeOrderStore(check: check)
    }

    // MARK: - 结算金额解析

    private static func settleProbe(check: (Bool, String) -> Void) {
        func money(_ json: String) -> Double? {
            if case let .found(v) = SettlementEngine.probeMoney(json) { return v }
            return nil
        }
        func isZero(_ json: String) -> Bool {
            if case .knownZero = SettlementEngine.probeMoney(json) { return true }
            return false
        }
        func isUnknown(_ json: String) -> Bool {
            if case .unknown = SettlementEngine.probeMoney(json) { return true }
            return false
        }

        // 厘 → 元：40 厘 = ¥0.04（漏了换算就是 ¥40，而且不报错）
        check(money(#"{"success":true,"data":{"consumeMoney":40}}"#) == 0.04,
              "consumeMoney 数字按厘换算成元")
        check(money(#"{"success":true,"data":{"consumeMoney":"40"}}"#) == 0.04,
              "consumeMoney 字符串也能按厘换算")
        check(money(#"{"data":{"consumeAmount":80}}"#) == 0.08,
              "consumeAmount 同样按厘换算")
        check(money(#"{"data":{"money":25}}"#) == 0.025,
              "money 字段兜底")

        // 字段在、值为 0 → knownZero（**不是** unknown：这决定零消费单子会不会卡住）
        check(isZero(#"{"success":true,"data":{"consumeMoney":0}}"#),
              "consumeMoney=0 判定为明确的零消费")
        check(isZero(#"{"data":{"consumeMoney":null}}"#) == false,
              "null 字段不算零消费")

        // 必须排除余额类字段：拿钱包余额当消费金额会报出大得离谱的数
        check(isUnknown(#"{"data":{"balance":100}}"#), "balance 不当消费金额")
        check(isUnknown(#"{"data":{"wallet":100}}"#), "wallet 不当消费金额")
        check(isUnknown(#"{"data":{"preDeductMoney":500}}"#), "preDeductMoney 不当消费金额")
        check(isUnknown(#"{"data":{"remainMoney":500}}"#), "remain 类字段不当消费金额")

        // 名字像金额但不在预期内 → 兜底命中（只认正数）
        check(money(#"{"data":{"serviceFee":3}}"#) == 0.003,
              "未知字段名按名字兜底并换算")
        check(isUnknown(#"{"data":{"serviceFee":0}}"#),
              "兜底命中的 0 不算零消费（宁可回退账单列表复核）")

        check(isUnknown("不是 JSON"), "非 JSON 响应判为未知而不是零消费")
        check(isUnknown(#"{"success":true,"data":null}"#), "data 为空判为未知")
    }

    // MARK: - 活跃订单仓库

    private static func activeOrderStore(check: (Bool, String) -> Void) {
        ActiveOrderStore.clear()

        let a = ActiveOrderRecord(snCode: "AAA", orderNo: "", deviceName: "320房",
                                  deviceMac: "AA", deviceEmoji: "🚿", preDeduct: 5)
        let b = ActiveOrderRecord(snCode: "BBB", orderNo: "132", deviceName: "321房",
                                  deviceMac: "BB", deviceEmoji: "🪥", preDeduct: 3)
        ActiveOrderStore.upsert(a)
        ActiveOrderStore.upsert(b)
        check(ActiveOrderStore.all().count == 2, "upsert 两台设备都在")
        check(ActiveOrderStore.isRunning("AAA") && ActiveOrderStore.isRunning("BBB"),
              "isRunning 两台都成立")

        // 同 snCode 再 upsert 不能产生重复
        ActiveOrderStore.upsert(b)
        check(ActiveOrderStore.all().count == 2, "同 snCode 重复 upsert 不产生重复条目")

        // 只补 orderNo，不整条覆盖
        ActiveOrderStore.updateOrderNo(snCode: "AAA", orderNo: "999")
        check(ActiveOrderStore.find("AAA")?.orderNo == "999", "updateOrderNo 补上订单号")
        check(ActiveOrderStore.find("AAA")?.deviceName == "320房", "updateOrderNo 不动其它字段")

        // 空 orderNo 不能把已有值冲掉
        ActiveOrderStore.updateOrderNo(snCode: "AAA", orderNo: "")
        check(ActiveOrderStore.find("AAA")?.orderNo == "999", "空 orderNo 不覆盖已有值")

        // 并发写回：整份列表不能被后写覆盖
        for i in 0 ..< 20 {
            ActiveOrderStore.update { list in
                list.append(ActiveOrderRecord(snCode: "S\(i)", orderNo: "", deviceName: "",
                                              deviceMac: "", deviceEmoji: "🚿", preDeduct: 0))
            }
        }
        check(ActiveOrderStore.all().count == 22, "并发 update 不丢条目")

        ActiveOrderStore.remove("AAA")
        check(ActiveOrderStore.find("AAA") == nil && ActiveOrderStore.all().count == 21,
              "remove 只删指定设备")
        check(!ActiveOrderStore.isRunning(""), "空 snCode 不算在用水")

        ActiveOrderStore.clear()
        check(ActiveOrderStore.all().isEmpty, "clear 清空全部活跃订单")
    }
}
