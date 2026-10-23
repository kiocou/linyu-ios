import Foundation

enum DeviceControlRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        let a = ActiveOrderRecord(snCode: "A", orderNo: "order-A", deviceName: "A",
                                  deviceMac: "A", deviceEmoji: "", preDeduct: 0)
        let b = ActiveOrderRecord(snCode: "B", orderNo: "order-B", deviceName: "B",
                                  deviceMac: "B", deviceEmoji: "", preDeduct: 0)
        let target = DeviceNotificationTarget(accountKey: "school:user", snCode: "A",
                                               orderNo: "order-A", startedAt: 100)
        check(target.matches(accountKey: "school:user", record: a, startedAt: 100), "通知可匹配原设备原订单")
        check(!target.matches(accountKey: "school:user", record: b, startedAt: 100), "A 通知不能操作当前显示的 B")
        check(!target.matches(accountKey: "other:user", record: a, startedAt: 100), "换账号后拒绝旧通知")
        check(!target.matches(accountKey: "school:user", record: a, startedAt: 200), "同设备新一轮用水拒绝旧通知")
        check(!target.matches(accountKey: "school:user", record: nil, startedAt: 100), "已结束订单不会因通知重新开阀")
        var changed = a; changed.orderNo = "new-order"
        check(!target.matches(accountKey: "school:user", record: changed, startedAt: 100), "订单号变化拒绝旧通知")
        let pending = DeviceNotificationTarget(accountKey: "school:user", snCode: "A", orderNo: "", startedAt: 100)
        check(pending.matches(accountKey: "school:user", record: a, startedAt: 100), "通知发出后补齐订单号仍能匹配")
        check(DeviceNotificationTarget(userInfo: [:]) == nil, "旧版无设备身份通知不会退回当前设备")
        check(DeviceNotificationTarget(userInfo: target.userInfo) == target, "通知载荷完整往返")
        check(target.matchesServerOrder(record: a, orderNo: "order-A", isOwner: true), "通知停止前确认服务器原订单")
        check(!target.matchesServerOrder(record: a, orderNo: "remote-new-order", isOwner: true), "旧通知不能关闭远端重开的订单")
        check(!target.matchesServerOrder(record: a, orderNo: "order-A", isOwner: false), "通知不能关闭他人的订单")
        var unknown = a; unknown.orderNo = ""
        check(!pending.matchesServerOrder(record: unknown, orderNo: "unknown", isOwner: true), "没有原订单号时不猜测通知目标")
        check(DeviceNotificationTarget.notificationID(snCode: "A", finished: false) != DeviceNotificationTarget.notificationID(snCode: "B", finished: false), "两台设备通知互不覆盖")
        var gate = DeviceControlGate()
        let first = gate.begin()!
        check(gate.begin() == nil, "已有控制或蓝牙结算时拒绝另一条控制链")
        gate.finish(UUID())
        check(gate.isBusy, "其它任务不能释放控制锁")
        gate.finish(first)
        let second = gate.begin()
        check(second != nil, "结算结束后允许下一台设备操作")
        gate.finish(first)
        check(gate.isBusy, "旧任务结束不能释放新的操作锁")
        gate.finish(second!)

        ApiClient.postPaths = []
        _ = await CloudShower.open(snCode: "A", allowNewOrder: false)
        check(ApiClient.postPaths == ["/order/tcpDevice/query/rateOrder/using"], "恢复空闲设备只查询，不申请新费率")
        ApiClient.postPaths = []; ApiClient.failPost = true
        _ = await CloudShower.open(snCode: "A", allowNewOrder: false)
        check(ApiClient.postPaths == ["/order/tcpDevice/query/rateOrder/using"], "恢复查询断网不会转成开阀")
        ApiClient.failPost = false
        ApiClient.postResponse = #"{"success":false,"errorCode":307,"data":{"orderNo":"old-order","isOwner":true}}"#
        if case let .resumed(orderNo, _) = await CloudShower.open(snCode: "A", allowNewOrder: false) {
            check(orderNo == "old-order", "恢复沿用服务器原订单号")
        } else { check(false, "恢复沿用服务器原订单号") }
        if case .failed = await CloudShower.open(snCode: "A", allowNewOrder: false, expectedOrderNo: "different-order") {
            check(true, "恢复时拒绝用另一笔服务器订单覆盖原订单")
        } else { check(false, "恢复时拒绝用另一笔服务器订单覆盖原订单") }
        ApiClient.postResponse = #"{"success":false,"errorCode":307,"data":{"orderNo":"other-order","isOwner":false}}"#
        if case .inUseByOthers = await CloudShower.open(snCode: "A", allowNewOrder: false) {
            check(true, "恢复拒绝他人订单")
        } else { check(false, "恢复拒绝他人订单") }
        ApiClient.postResponse = #"{"success":true,"data":null}"#
    }
}
