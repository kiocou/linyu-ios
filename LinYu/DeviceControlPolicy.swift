import Foundation

/// Android 通知 PendingIntent 携带 snCode；iOS 还保存订单身份，拒绝旧通知操作新订单。
struct DeviceNotificationTarget: Equatable {
    let accountKey: String
    let snCode: String
    let orderNo: String
    let startedAt: Int64

    var userInfo: [String: String] {
        ["accountKey": accountKey, "snCode": snCode, "orderNo": orderNo,
         "startedAt": String(startedAt)]
    }

    init(accountKey: String, snCode: String, orderNo: String, startedAt: Int64) {
        self.accountKey = accountKey; self.snCode = snCode
        self.orderNo = orderNo; self.startedAt = startedAt
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let account = userInfo["accountKey"] as? String, !account.isEmpty,
              let sn = userInfo["snCode"] as? String, !sn.isEmpty,
              let start = userInfo["startedAt"] as? String, let timestamp = Int64(start), timestamp > 0
        else { return nil }
        self.init(accountKey: account, snCode: sn,
                  orderNo: userInfo["orderNo"] as? String ?? "", startedAt: timestamp)
    }

    func matches(accountKey: String, record: ActiveOrderRecord?, startedAt: Int64) -> Bool {
        guard !self.accountKey.isEmpty, self.accountKey == accountKey,
              let record, !snCode.isEmpty, record.snCode == snCode,
              self.startedAt > 0, self.startedAt == startedAt else { return false }
        return orderNo.isEmpty || record.orderNo.isEmpty || orderNo == record.orderNo
    }

    static func notificationID(snCode: String, finished: Bool) -> String {
        "linyu.\(finished ? "finished" : "inUse")." + snCode
    }

    func matchesServerOrder(record: ActiveOrderRecord, orderNo: String?, isOwner: Bool?) -> Bool {
        let expected = self.orderNo.isEmpty ? record.orderNo : self.orderNo
        return record.snCode == snCode && !expected.isEmpty && orderNo == expected && isOwner != false
    }
}

struct DeviceNotificationAction: Identifiable, Equatable {
    let id = UUID()
    let target: DeviceNotificationTarget
    let stop: Bool
}

/// 一个共享 BLE 会话只能处理一条控制链；关阀后的重连结算也占用此锁。
/// token 避免旧任务释放后来操作持有的锁。
struct DeviceControlGate {
    private(set) var token: UUID?
    var isBusy: Bool { token != nil }
    mutating func begin() -> UUID? {
        guard token == nil else { return nil }
        let next = UUID(); token = next; return next
    }
    mutating func finish(_ owner: UUID) {
        if token == owner { token = nil }
    }
}
