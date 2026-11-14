import Foundation

enum SessionIsolationRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        let suite = "linyu.session-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("A-order", forKey: "activeOrders")
        defaults.set(1234, forKey: "startedAt_device")
        defaults.set("ble-state", forKey: "bleSessionJson")
        RecoveryArchive.bindExisting(owner: "school:A", defaults: defaults)
        RecoveryArchive.suspend(owner: "school:A", preserve: true, defaults: defaults)
        check(defaults.object(forKey: "activeOrders") == nil, "挤号后当前可见区不残留订单")
        RecoveryArchive.activate(owner: "school:B", defaults: defaults)
        check(defaults.object(forKey: "activeOrders") == nil && defaults.object(forKey: "bleSessionJson") == nil, "B登录不能认领A的订单和蓝牙恢复态")
        RecoveryArchive.suspend(owner: "school:B", preserve: false, defaults: defaults)
        RecoveryArchive.activate(owner: "school:A", defaults: defaults)
        check(defaults.string(forKey: "activeOrders") == "A-order" && defaults.integer(forKey: "startedAt_device") == 1234, "A重登保留订单及计时")
        check(defaults.string(forKey: "bleSessionJson") == "ble-state", "A重登恢复蓝牙会话记录")
        RecoveryArchive.suspend(owner: "school:A", preserve: false, defaults: defaults)
        RecoveryArchive.activate(owner: "school:A", defaults: defaults)
        check(defaults.object(forKey: "activeOrders") == nil, "主动退出不会复活旧归档")
        defaults.removePersistentDomain(forName: suite)
        defaults.set("unknown-order", forKey: "activeOrders")
        RecoveryArchive.activate(owner: "school:B", defaults: defaults)
        check(defaults.object(forKey: "activeOrders") == nil && defaults.dictionary(forKey: "linyu.unassignedRecovery")?["activeOrders"] as? String == "unknown-order", "无归属旧数据隔离保存，不自动交给新账号")

        let scope = SessionWorkScope()
        var started = false
        let task = Task {
            await scope.run(fallback: false) {
                started = true
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { return Task.isCancelled }
                return false
            }
        }
        while !started { await Task.yield() }
        scope.cancel()
        let cancelled = await task.value
        check(cancelled, "取消会话作用域会唤醒并取消子任务")
        let rejected = await scope.run(fallback: true) { false }
        check(rejected, "结束后的作用域不再接纳任务")
        let previous = Session.shared.requestGeneration
        Session.shared.requestGeneration = UUID()
        check(!SessionWork.isCurrent(previous), "同账号重新登录旧代次仍然失效")

        PendingSettlementStore.clearAll()
        ApiClient.postPaths = []
        ApiClient.postResponse = #"{"success":true,"data":{"consumeMoney":5000}}"#
        ApiClient.onPost = { Session.shared.requestGeneration = UUID() }
        Prefs.recordedConsume.removeValue(forKey: "stale-device")
        let result = await SettlementEngine.settleAmount(orderNo: "old", startTimeMs: 1, snCode: "stale-device")
        check(result == nil && Prefs.recordedConsume["stale-device"] == nil, "结算响应期间换号不记金额")
        check(ApiClient.postPaths.count == 1 && PendingSettlementStore.all().isEmpty, "失效结算不再重试或登记待对账")
        ApiClient.onPost = nil
        ApiClient.postPaths = []
        ApiClient.onPost = { Session.shared.requestGeneration = UUID() }
        ApiClient.postResponse = #"{"success":true,"data":null}"#
        _ = await CloudShower.open(snCode: "old-device")
        check(!ApiClient.postPaths.contains("/order/tcpDevice/downRate/rateOrder"), "查询期间换号不能继续申请新费率")
        ApiClient.onPost = nil
        ApiClient.postResponse = #"{"success":true,"data":null}"#
        ApiClient.getResponses["/order/query/account/unpaid/list"] = #"{"success":true,"data":[]}"#
        let deduct = DeductService()
        Session.shared.requestGeneration = UUID()
        ApiClient.postPaths = []
        _ = await deduct.requestDeduct(consumeDate: "old-date")
        check(ApiClient.postPaths.isEmpty, "旧账号代扣服务不能使用新凭据发起扣款")
        ApiClient.getResponses = [:]
    }
}
