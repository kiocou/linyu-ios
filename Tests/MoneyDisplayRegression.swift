import Foundation

enum MoneyDisplayRegression {
    static func run(check: (Bool, String) -> Void) {
        for (value, expected) in [(0.0, "0.00"), (2.0, "2.00"), (2.1, "2.10"),
                                  (2.10, "2.10"), (2.101, "2.101"), (0.025, "0.025"),
                                  (1.84, "1.84"), (55.46, "55.46"), (-2.1, "-2.10")] {
            check(MoneyFormat.format(value) == expected, "金额 \(value) 固定至少两位：\(expected)")
            check(MoneyFormat.withSymbol(value) == "¥" + expected, "带符号金额保持精度：\(expected)")
        }
        for raw in ["2", "2.0", "2.00", "2.000", "2.1", "2.10", "2.100", "0.025"] {
            let bill = try! JSONDecoder().decode(BillDTO.self,
                from: Data("{\"consumeMoney\":\"\(raw)\"}".utf8))
            let expected = raw.hasPrefix("2.1") ? "2.10" : raw == "0.025" ? "0.025" : "2.00"
            check(bill.yuan.map { MoneyFormat.format($0) } == expected, "服务端账单字符串统一格式：\(raw)")
        }
        check(MoneyFormat.withSymbol(nil as Double?) == "¥ —", "未知金额不伪装为零")
        check(PreDeductPolicy.resolve(device: 5, response: 0) == 5, "云端接口占位 0 不覆盖设备预扣 5")
        check(PreDeductPolicy.resolve(device: 5, response: nil) == 5, "开阀未返回预扣时采用设备配置")
        check(PreDeductPolicy.resolve(device: 5, savedOrder: 0) == 5, "恢复旧订单的错误零预扣")
        check(PreDeductPolicy.resolve(device: 5, response: 3) == 5, "与安卓一致优先设备预扣")
        check(PreDeductPolicy.resolve(device: 0, savedOrder: 5, response: 5) == 0, "设备明确配置零时不套用历史金额")
        check(PreDeductPolicy.resolve(device: nil, savedOrder: 3, lastDevice: 5) == 3, "缺设备资料时沿用同设备订单")
        check(PreDeductPolicy.resolve(device: nil, savedOrder: 0, lastDevice: 5, response: 0) == 5, "组件恢复采用同设备缓存")
        check(PreDeductPolicy.resolve(device: nil, response: 2.105) == 2.105, "缺少设备与缓存时保留响应精度")
        check(PreDeductPolicy.resolve(device: nil) == 0, "完全未知时不借用其他设备额度")
        check(PreDeductPolicy.resolve(device: .nan, savedOrder: -1, lastDevice: .infinity) == 0, "忽略非法预扣值")
    }
}
