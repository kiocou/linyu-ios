import Foundation

enum ConsumptionCachePolicy {
    static func shouldUpdate(sameDevice: Bool, amount: Double, billTime: Double, cachedTime: Double) -> Bool {
        sameDevice && amount.isFinite && amount > 0 && billTime.isFinite && billTime > 0 && billTime > cachedTime
    }
}
