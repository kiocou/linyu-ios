import Foundation

enum ParityFinishRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        let suite = "linyu.parity-finish." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bill = try! JSONDecoder().decode(BillDTO.self, from: Data(#"{"orderId":"1","consumeMoney":"2.5"}"#.utf8))
        BillHistoryCache.save([bill], owner: "A", defaults: defaults)
        check(BillHistoryCache.read(owner: "A", defaults: defaults)?.first?.yuan == 2.5, "账单快照保留元金额")
        check(BillHistoryCache.read(owner: "B", defaults: defaults) == nil, "不同账号不能读取账单快照")
        BillHistoryCache.save([], owner: "A", defaults: defaults)
        check(BillHistoryCache.read(owner: "A", defaults: defaults)?.isEmpty == true, "成功空账单覆盖旧快照")
        defaults.set(Data("broken".utf8), forKey: "billCache_A")
        check(BillHistoryCache.read(owner: "A", defaults: defaults) == nil, "损坏账单缓存不视为成功空账单")

        let owner = "cache-test:" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "billCache_" + owner) }
        BillHistoryCache.save([bill], owner: owner)
        let store = AppDataStore(profileOwnerProvider: { owner })
        check(store.loaded && store.bills.first?.orderId == "1", "冷启动立即展示本账号账单缓存")
        ApiClient.failBills = true
        await store.loadIfNeeded()
        check(store.bills.first?.orderId == "1" && store.billsError != nil, "有磁盘缓存仍尝试刷新，失败保留旧账单")
        ApiClient.failBills = false
        await store.loadIfNeeded()
        check(store.bills.count == 3 && store.billsError == nil, "缓存刷新失败后允许重试")

        let recovery = BleRecoveryRecord(owner: "A", snCode: "sn", orderNo: "order", startedAt: 100,
            protocolType: "20", randomNumber: "abcd", consumeDate: "consume-date")
        BleRecoveryStore.save(recovery, defaults: defaults)
        check(BleRecoveryStore.read(owner: "A", snCode: "sn", orderNo: "order", startedAt: 100, defaults: defaults)?.consumeDate == "consume-date", "蓝牙恢复保留失败上报所需消费时间戳")
        check(BleRecoveryStore.read(owner: "B", snCode: "sn", orderNo: "order", startedAt: 100, defaults: defaults) == nil, "蓝牙恢复拒绝不同账号")
        check(BleRecoveryStore.read(owner: "A", snCode: "sn", orderNo: "new", startedAt: 100, defaults: defaults) == nil, "蓝牙恢复拒绝同设备新订单")
        check(BleRecoveryStore.read(owner: "A", snCode: "sn", orderNo: "order", startedAt: 200, defaults: defaults) == nil, "蓝牙恢复拒绝不同开阀时间")
        BleRecoveryStore.remove(snCode: "sn", defaults: defaults)
        check(BleRecoveryStore.read(owner: "A", snCode: "sn", orderNo: "order", startedAt: 100, defaults: defaults) == nil, "结束后清除目标蓝牙恢复记录")

        check(SettlementNoticePolicy.shouldCorrect(createdAt: 100, notificationCreatedAt: 100, now: 100 + 1_800_000), "30分钟内允许更正同一笔结算通知")
        check(!SettlementNoticePolicy.shouldCorrect(createdAt: 100, notificationCreatedAt: 101, now: 200), "不覆盖同设备后来的通知")
        check(!SettlementNoticePolicy.shouldCorrect(createdAt: 100, notificationCreatedAt: 100, now: 100 + 1_800_001), "超过窗口不再补通知")
        check(TrendDisplayPolicy.plotX(index: 0, size: 1, width: 100, horizontalInset: 8) == 50, "单点趋势居中")
        check(TrendDisplayPolicy.plotX(index: 30, size: 31, width: 100, horizontalInset: 8) == 92, "月末趋势点保留右侧空间")
        check(TrendDisplayPolicy.axisIndices(size: 31, maxLabels: 1) == [0], "单标签横轴不除零")
        let masked = LogRedactor.mask(#"telephone=13812345678&loginCode=secret&signature=private {"password":"hidden"}"#)
        check(!masked.contains("secret") && !masked.contains("private") && !masked.contains("hidden") && masked.contains("138****5678"), "实际日志脱敏覆盖表单JSON及手机号")
    }
}
