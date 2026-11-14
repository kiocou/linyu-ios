import Foundation

enum NotificationFeedbackRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        for kind in [NotificationKind.inUse, .finished, .autoClosed, .closeProblem, .occupied, .openFailed] {
            check(!kind.enabled(master: false, inUse: true, finished: true, autoClose: true), "总开关禁止\(kind.rawValue)")
        }
        check(!NotificationKind.inUse.enabled(master: true, inUse: false, finished: true, autoClose: true), "状态通知独立关闭")
        check(NotificationKind.autoClosed.enabled(master: true, inUse: false, finished: false, autoClose: true), "关闭结束通知不影响自动关停")
        check(!NotificationKind.closeProblem.enabled(master: true, inUse: true, finished: false, autoClose: true), "关阀失败跟随安卓结束通知开关")
        check(NotificationKind.openFailed.enabled(master: true, inUse: false, finished: false, autoClose: false), "失败通知不被其他分类开关误拦")
        check(NotificationKind.finished.destination == 1 && NotificationKind.autoClosed.destination == 1 && NotificationKind.occupied.destination == 0, "结束去账单、占用去首页")
        check(!NotificationKind.inUse.urgent && !NotificationKind.finished.urgent && NotificationKind.openFailed.urgent, "计时静默、开阀失败使用提醒策略")
        defer { ApiClient.getResponses = [:]; ApiClient.postResponse = #"{"success":true,"data":null}"# }
        let owner = "quota-test:" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "useCodeQuota_" + owner) }
        let store = AppDataStore(profileOwnerProvider: { owner })
        ApiClient.postResponse = #"{"success":true,"data":{"useCode":"last-candidate","remainTimes":0}}"#
        do {
            let result = try await store.generateUseCode()
            check(result.useCode == "last-candidate" && store.useCodeQuotaExhausted, "第20次候选有效并记住剩余次数为零")
        } catch { check(false, "最后一次生成应成功") }
        ApiClient.postPaths = []
        do { _ = try await store.generateUseCode(); check(false, "额度耗尽不应继续换码") }
        catch { check(ApiClient.postPaths.isEmpty && store.useCodeBlockReason != nil, "额度耗尽在请求前拦截并解释原因") }
        check(AppDataStore(profileOwnerProvider: { owner }).useCodeQuotaExhausted, "同日重新创建缓存仍保留次数耗尽状态")
        check(UseCodeQuotaStore.read(owner: owner + "other") == nil, "不同账号不共用换码额度")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        check(UseCodeQuotaStore.read(owner: owner, now: tomorrow) == nil, "跨日不沿用昨日次数耗尽记录")
        let rejectedOwner = "quota-error:" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "useCodeQuota_" + rejectedOwner) }
        let rejected = AppDataStore(profileOwnerProvider: { rejectedOwner })
        ApiClient.postResponse = #"{"success":false,"errorCode":79,"errorMessage":"使用码生成次数超出日限制次数","data":null}"#
        do { _ = try await rejected.generateUseCode(); check(false, "服务端额度错误不能生成候选") }
        catch { check(rejected.useCodeQuotaExhausted, "错误79也记录当日额度耗尽") }
        check(AppDataStore(profileOwnerProvider: { rejectedOwner }).useCodeBlockReason != nil, "错误79持久化后重新进入仍拦截")
        ApiClient.postPaths = []
        do { _ = try await rejected.generateUseCode(); check(false, "错误79后不再请求换码") }
        catch { check(ApiClient.postPaths.isEmpty, "错误79后的重复点击不调用接口") }
    }
}
