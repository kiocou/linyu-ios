import Foundation

enum SharedStoreSessionRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        let originalGeneration = Session.shared.requestGeneration
        let owner = "store-session:" + UUID().uuidString
        defer {
            Session.shared.requestGeneration = originalGeneration
            ApiClient.onGet = nil
            ApiClient.onPost = nil
            ApiClient.getResponses = [:]
            ApiClient.postResponse = #"{"success":true,"data":null}"#
            ApiClient.delay = 0
            ApiClient.failPost = false
        }
        ApiClient.getResponses["/account/useCode/new"] = #"{"success":true,"data":{"useCode":"123456","useCodeStatus":1}}"#
        let stale = AppDataStore(profileOwnerProvider: { owner })
        ApiClient.onGet = { _ in Session.shared.requestGeneration = UUID() }
        let loaded = await stale.loadUseCode()
        check(!loaded && !stale.useCodeLoaded && stale.useCode == nil,
              "使用码响应期间同账号重登，旧结果不落内存")
        ApiClient.onGet = nil
        stale.acceptUseCode("old-claim")
        check(stale.useCode == nil, "旧领取回调不更新新登录会话")
        ApiClient.getPaths = []
        _ = await stale.loadUseCode(force: true)
        await stale.loadProfileIfNeeded()
        await stale.deviceInfo("old-device")
        await stale.reload()
        check(ApiClient.getPaths.isEmpty, "失效共享缓存不能借新会话发请求")
        ApiClient.postPaths = []
        do { try await stale.setUseCodeEnabled(false); check(false, "旧实例切换使用码应取消") }
        catch { check(error is CancellationError, "旧实例切换使用码报告取消") }
        check(ApiClient.postPaths.isEmpty, "失效使用码开关不发送写请求")

        let current = AppDataStore(profileOwnerProvider: { owner })
        current.cancelRequestsIfSessionEnded()
        let currentLoaded = await current.loadUseCode()
        check(currentLoaded && current.useCode?.useCode == "123456", "暂时离开页面不销毁有效会话，仍正常加载使用码")
        ApiClient.onPost = { Session.shared.requestGeneration = UUID() }
        do { try await current.setUseCodeEnabled(false); check(false, "开关响应换会话应取消") }
        catch { check(error is CancellationError, "开关响应期间换会话不报告成功") }
        check(current.useCode?.useCodeStatus == 1, "开关旧响应不改缓存状态")
        ApiClient.onPost = nil

        let profile = AppDataStore(profileOwnerProvider: { owner })
        ApiClient.getPaths = []
        ApiClient.onGet = { _ in Session.shared.requestGeneration = UUID() }
        await profile.loadProfileIfNeeded()
        check(!profile.profileLoaded && profile.accountInfo == nil,
              "个人资料响应期间重登不落盘或发布旧身份")
        check(!ApiClient.getPaths.contains("/account/card/getBindCardInfo") &&
              !ApiClient.getPaths.contains("/settlement/campus/userInfo"),
              "会话失效后不继续查询身份兜底接口")
        ApiClient.onGet = nil

        let codes = AppDataStore(profileOwnerProvider: { owner })
        codes.acceptUseCode("current-code")
        ApiClient.getResponses["/account/useCode/new"] = #"{"success":true,"data":null}"#
        let emptyRefresh = await codes.loadUseCode(force: true)
        check(emptyRefresh && codes.useCode?.useCode == "current-code", "成功空响应不抹掉已领取使用码")
        ApiClient.getResponses["/account/useCode/new"] = #"{"success":false,"errorCode":500,"errorMessage":"查询失败","data":null}"#
        let failedRefresh = await codes.loadUseCode(force: true)
        check(!failedRefresh && codes.useCode?.useCode == "current-code", "业务失败保留原使用码且允许重试")
        ApiClient.postResponse = #"{"success":false,"errorCode":400,"errorMessage":"今日已领取","data":null}"#
        ApiClient.getPaths = []
        do { try await codes.claimUseCode("rejected"); check(false, "业务拒绝领取不能成功") }
        catch ApiError.business { check(true, "领取业务拒绝明确失败") }
        catch { check(false, "领取业务拒绝类型") }
        check(codes.useCode?.useCode == "current-code" && ApiClient.getPaths.isEmpty,
              "领取失败不换码、不触发成功后的刷新")
        ApiClient.getResponses["/account/useCode/new"] = #"{"success":true,"data":{"useCode":"123456","useCodeStatus":1}}"#
        ApiClient.postResponse = #"{"success":true,"data":{"useCode":"candidate","remainTimes":8}}"#
        do {
            let candidate = try await codes.generateUseCode()
            check(candidate.useCode == "candidate" && candidate.remainTimes == 8,
                  "换码返回候选与剩余次数")
            check(codes.useCode?.useCode == "current-code", "生成候选不覆盖当前生效码")
        } catch { check(false, "有效会话应能生成候选") }
        ApiClient.delay = 1_000_000
        let oldRead = Task { await codes.loadUseCode(force: true) }
        while ApiClient.activeRequests == 0 { await Task.yield() }
        codes.acceptUseCode("confirmed-new-code")
        let oldReadAccepted = await oldRead.value
        ApiClient.delay = 0
        check(!oldReadAccepted && codes.useCode?.useCode == "confirmed-new-code",
              "领取前发出的查询不能覆盖领取后的新码")
        ApiClient.onPost = { Session.shared.requestGeneration = UUID() }
        do { try await codes.claimUseCode("candidate"); check(false, "领取响应失效应取消") }
        catch { check(error is CancellationError, "领取响应换会话不调用成功路径") }
        check(codes.useCode?.useCode == "confirmed-new-code", "失效领取响应不改当前码")
        ApiClient.onPost = nil
        ApiClient.postPaths = []
        do { _ = try await codes.generateUseCode(); check(false, "旧弹窗换码应取消") }
        catch { check(error is CancellationError, "旧弹窗不能继续生成候选") }
        do { try await codes.claimUseCode("candidate"); check(false, "旧弹窗领取应取消") }
        catch { check(error is CancellationError, "旧弹窗不能继续领取") }
        check(ApiClient.postPaths.isEmpty, "旧候选操作不会借新会话发出写请求")

        let cancelled = AppDataStore(profileOwnerProvider: { owner })
        cancelled.cancelRequests()
        ApiClient.getPaths = []
        _ = await cancelled.loadUseCode(force: true)
        cancelled.acceptUseCode("cancelled")
        await cancelled.loadProfileIfNeeded()
        check(ApiClient.getPaths.isEmpty && cancelled.useCode == nil,
              "已销毁页面的共享缓存拒绝后续请求和领取回调")
    }
}
