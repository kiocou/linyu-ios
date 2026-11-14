import Foundation

/// 展示用预扣额度，与 Android enterShowerState / ensureActiveOrder 一致：设备配置优先。
/// 订单接口可能返回占位 0，不能用它覆盖设备的 withholdMoney；不改变扣款或结算请求。
enum PreDeductPolicy {
    static func resolve(device: Double?, savedOrder: Double? = nil,
                        lastDevice: Double? = nil, response: Double? = nil) -> Double {
        // 设备明确配置的 0 是有效值，不借用历史正金额。
        if let device, device.isFinite, device >= 0 { return device }
        // 兼容旧版存下的占位 0；调用方只允许传入同一设备的缓存。
        for value in [savedOrder, lastDevice, response].compactMap({ $0 }) {
            if value.isFinite, value > 0 { return value }
        }
        return 0
    }
}
