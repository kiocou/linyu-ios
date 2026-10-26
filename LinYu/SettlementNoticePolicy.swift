import Foundation

enum SettlementNoticePolicy {
    static let graceMs: Int64 = 30 * 60 * 1000
    static func shouldCorrect(createdAt: Int64, notificationCreatedAt: Int64, now: Int64) -> Bool {
        createdAt > 0 && createdAt == notificationCreatedAt && now >= createdAt && now - createdAt <= graceMs
    }
}
