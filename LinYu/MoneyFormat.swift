import Foundation

/// 金额显示的统一格式化 —— 对照 Android 的 `MoneyFormat.kt`。
///
/// ## 为什么不能直接 `%.2f`
///
/// 服务端金额以**厘**（0.001 元）为单位传输：蓝牙结算返回 `upMoney=25` 就是 ¥0.025，
/// 账单里也写着 `0.025`。用 `%.2f` 会四舍五入成 `¥0.03`，
/// 用户看到账单是 0.025、提示却写 0.03，会以为多扣了钱（Android 2026-09-30 实测反馈）。
///
/// 所以统一保留 **3 位小数**；**末位为 0 时收敛为 2 位** —— 有些学校精度只到分，
/// 金额常年是 `5.000`，硬留 3 位会多一个无意义的 0。
enum MoneyFormat {

    /// `0.025` → `"0.025"`；`5.0` → `"5.0"`
    static func format(_ value: Double) -> String {
        let s = String(format: "%.3f", value)
        return s.hasSuffix("0") ? String(s.dropLast()) : s
    }

    /// 带 ¥ 前缀
    static func withSymbol(_ value: Double) -> String { "¥\(format(value))" }

    /// 可空版本：nil 显示 `¥ —`（不是 ¥0.00，"不知道"和"没花钱"是两件事）
    static func withSymbol(_ value: Double?) -> String {
        guard let value else { return "¥ —" }
        return withSymbol(value)
    }

    /// 厘 → 元
    static func milliToYuan(_ milli: Int?) -> Double? {
        milli.map { Double($0) / 1000.0 }
    }
}
