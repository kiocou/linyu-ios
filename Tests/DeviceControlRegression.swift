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
        ApiClient.postPaths = []
        if case .closed = await CloudShower.close(snCode: "A", orderNo: "order-A") {
            check(ApiClient.postPaths == ["/order/tcpDevice/closeOrder"], "服务端受理关阀后立即返回，不等待仅供日志使用的查询")
        } else { check(false, "服务端受理关阀后立即返回，不等待仅供日志使用的查询") }

        ActiveOrderStore.clear()
        ActiveOrderStore.upsert(a)
        ActiveOrderStore.upsert(b)
        ActiveOrderStore.finish("A")
        check(!ActiveOrderStore.isRunning("A") && ActiveOrderStore.isRunning("B"), "结束 A 立即移除 A 并保留 B")
        check(ActiveOrderStore.wasFinished(snCode: "A", orderNo: "order-A"), "已结束订单身份落盘，迟到查询不能恢复")
        check(!ActiveOrderStore.wasFinished(snCode: "A", orderNo: "next-order"), "同设备的新订单不会被旧订单拦截")
        check(!ActiveOrderStore.wasFinished(snCode: "B", orderNo: "order-A"), "结束记录按设备隔离")
        ActiveOrderStore.confirmIdle("A")
        check(ActiveOrderStore.wasFinished(snCode: "A", orderNo: "order-A"), "空闲确认后仍拒绝迟到的已知旧订单")
        var noNumber = b; noNumber.orderNo = ""
        ActiveOrderStore.upsert(noNumber)
        ActiveOrderStore.finish("B")
        check(ActiveOrderStore.wasFinished(snCode: "B", orderNo: "late-number"), "结束时订单号未知先拦截延迟补号")
        ActiveOrderStore.confirmIdle("B")
        check(!ActiveOrderStore.wasFinished(snCode: "B", orderNo: "next-B"), "确认空闲后解除未知订单号拦截")
        ApiClient.postPaths = []
        ApiClient.postResponse = #"{"success":false,"errorCode":307,"data":{"orderNo":"order-A","isOwner":true}}"#
        if case .failed = await CloudShower.open(snCode: "A") {
            check(!ApiClient.postPaths.contains("/order/tcpDevice/downRate/rateOrder"), "关阀后旧订单仍在服务器时不能恢复或重复开阀")
        } else { check(false, "关阀后旧订单仍在服务器时不能恢复或重复开阀") }
        ActiveOrderStore.clear()
        check(!ActiveOrderStore.wasFinished(snCode: "A", orderNo: "order-A"), "退出账号清理结束订单身份")
        ApiClient.postResponse = #"{"success":true,"data":null}"#
        ApiClient.failPost = true
        if case .unconfirmed = await CloudShower.close(snCode: "A", orderNo: "order-A") {
            check(true, "断网关阀不冒充已关闭")
        } else { check(false, "断网关阀不冒充已关闭") }
        ApiClient.failPost = false
    }
}
