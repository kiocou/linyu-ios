import Combine
import Foundation

/// 跨页面共享的数据 —— **iOS 版的 "ViewModel"**。
///
/// ## 为什么要有这个
///
/// Android 那边账单、余额都存在 `MainViewModel` 里，而 ViewModel 的生命周期
/// 比页面长：切走再切回来，页面重建但数据还在，不会重新拉接口。
///
/// iOS 的 `View` 每次切回来都是**新的实例**，`@State` 会重新初始化，
/// 于是每切一次就重新请求一次账单 —— 用户看到的就是「明明加载过，切回来又要等」。
///
/// 所以把账单/余额提到这一层（由 `MainTabView` 持有，和 ViewModel 一个位置），
/// 页面只负责读。下拉刷新时才显式调 `reload()`。
@MainActor
final class AppDataStore: ObservableObject {

    /// 完整账单（最近 3 个月），趋势图用
    @Published private(set) var bills: [BillDTO] = []
    @Published private(set) var loading = false
    /// 是否已经成功加载过一次。
    ///
    /// ⚠️ 有了它才能区分「还没加载」和「加载完是空的」——
    /// 账单真的为空时不能一直转圈，也不能拿空数组去算出一个假的余额。
    @Published private(set) var loaded = false
    @Published private(set) var billsError: String?

    /// 台账（snCode → DeviceInfo）。
    ///
    /// ⚠️ 必须放这里：放到页面的 `@State` 里，切走再切回来页面重建就丢了，
    /// 设备列表会先闪回广播名（`KLCXKJ-Water`）再变回房间名。
    /// Android 那边这份数据在 MainViewModel 里，跨页面一直在。
    @Published private(set) var deviceInfos: [String: DeviceInfo] = [:]
    @Published private(set) var deviceLookupMessages: [String: String] = [:]
    /// 正在查询的 snCode，避免同一台设备并发重复请求
    private var resolving: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    @Published private(set) var accountInfo: AccountInfo?
    @Published private(set) var projectName = ""
    @Published private(set) var useCode: UseCodeData?
    @Published private(set) var useCodeLoaded = false
    @Published private(set) var changingUseCodeStatus = false
    @Published private(set) var profileLoaded = false
    @Published private(set) var profileError: String?
    private var profileTask: Task<Void, Never>?
    private var useCodeTask: Task<Bool, Never>?
    private var useCodeRevision = 0
    @Published private(set) var useCodeRemaining: Int?
    private var useCodeQuotaDate: Date?
    var useCodeQuotaExhausted: Bool {
        useCodeRemaining == 0 && useCodeQuotaDate.map { Calendar.current.isDateInToday($0) } == true
    }
    var useCodeBlockReason: String? {
        if useCode?.resetAvailability == 0 {
            return useCode?.resetAvailabilityWarMark ?? "1天只能领取一次使用码"
        }
        return useCodeQuotaExhausted ? "今日换码次数已用完，请明天再试" : nil
    }
    private var billsTask: Task<Void, Never>?
    private var profileRefreshed = false
    private var billsRefreshed = false
    var onBillsLoaded: (([BillDTO]) -> Void)?
    private let generation = Session.shared.requestGeneration
    private var requestsCancelled = false
    private var sessionIsCurrent: Bool {
        !requestsCancelled && SessionWork.isCurrent(generation) && currentProfileOwner() == profileOwner
    }
    private let profileOwner: String
    private let currentProfileOwner: () -> String

    init(profileOwnerProvider: @escaping () -> String = {
        let session = Session.shared
        return session.isLoggedIn ? session.projectId + ":" + session.accountId : ""
    }) {
        currentProfileOwner = profileOwnerProvider
        profileOwner = profileOwnerProvider()
        if let quota = UseCodeQuotaStore.read(owner: profileOwner) {
            useCodeRemaining = quota.remaining
            useCodeQuotaDate = quota.date
        }
        if let cached = BillHistoryCache.read(owner: profileOwner) {
            bills = cached
            loaded = true
        }
        if let cached = ProfileCache.read(owner: profileOwner) {
            accountInfo = cached.info
            projectName = cached.projectName
            profileLoaded = true
        }
    }

    func loadProfileIfNeeded() async {
        guard sessionIsCurrent, !profileRefreshed, !profileOwner.isEmpty else { return }
        if let profileTask { await profileTask.value; return }
        let task = Task { @MainActor in
            defer { self.profileTask = nil }
            self.profileError = nil
            async let account = BillService.loadAccountInfo()
            async let project = BillService.loadProjectInfo()
            let (accountResult, projectResult) = await (account, project)
            guard self.sessionIsCurrent else { return }
            var merged = accountResult ?? self.accountInfo ?? .empty
            var identitySourceLoaded = accountResult != nil
            if merged.needsIdentity, let bound = await BillService.loadBindCardInfo() {
                identitySourceLoaded = true
                merged.fillIdentity(name: bound.name, studentId: bound.idCardNumber)
            }
            guard self.sessionIsCurrent else { return }
            if merged.needsIdentity, let campus = await BillService.loadCampusInfo() {
                identitySourceLoaded = true
                merged.fillIdentity(name: campus.studentName, studentId: campus.studentNumber)
            }
            guard self.sessionIsCurrent else { return }
            // 新响应缺字段不抹掉已知资料；有效的新账号响应优先于旧缓存。
            merged.fillIdentity(name: self.accountInfo?.name, studentId: self.accountInfo?.idCardNumber)
            self.accountInfo = merged
            if let name = projectResult?.projectName, !name.isEmpty { self.projectName = name }
            self.profileRefreshed = identitySourceLoaded && projectResult != nil
            self.profileLoaded = self.profileLoaded || identitySourceLoaded || projectResult != nil
            if self.profileLoaded {
                ProfileCache.save(owner: self.profileOwner, info: merged, projectName: self.projectName)
            }
            if !self.profileRefreshed { self.profileError = "获取个人信息失败，请重试" }
        }
        profileTask = task
        await task.value
    }

    @discardableResult
    func loadUseCode(force: Bool = false) async -> Bool {
        guard sessionIsCurrent else { return false }
        if let useCodeTask { return await useCodeTask.value }
        if !force && useCodeLoaded { return true }
        let revision = useCodeRevision
        let task = Task { @MainActor in
            defer { self.useCodeTask = nil }
            do {
                let raw = try await ApiClient.get("/account/useCode/new", tag: "useCode")
                let result = try ApiClient.decode(UseCodeData.self, from: raw, path: "useCode").data
                try Task.checkCancellation()
                guard self.sessionIsCurrent, self.useCodeRevision == revision else { return false }
                // Android 只在 data 非空时替换已有使用码；空响应不能抹掉刚领取的码。
                if let result { self.useCode = result }
                self.useCodeLoaded = true
                return true
            } catch {
                guard self.sessionIsCurrent else { return false }
                AppLog.shared.w("使用码加载失败：\(error.localizedDescription)")
                return false
            }
        }
        useCodeTask = task
        return await task.value
    }

    func setUseCodeEnabled(_ enabled: Bool) async throws {
        guard sessionIsCurrent else { throw CancellationError() }
        guard !changingUseCodeStatus else { return }
        changingUseCodeStatus = true
        defer { changingUseCodeStatus = false }
        let raw = try await ApiClient.post("/account/useCode/new/status/update",
            form: ["useCodeStatus": enabled ? "1" : "0"], tag: "useCodeStatus")
        guard sessionIsCurrent else { throw CancellationError() }
        _ = try ApiClient.decode(EmptyData.self, from: raw, path: "useCodeStatus")
        useCodeRevision += 1
        useCode?.useCodeStatus = enabled ? 1 : 0
    }

    func acceptUseCode(_ code: String) {
        guard sessionIsCurrent else { return }
        useCodeRevision += 1
        useCode = UseCodeData(useCode: code, useCodeStatus: useCode?.useCodeStatus,
            useCodeRandom: useCode?.useCodeRandom, useCodeStartTime: useCode?.useCodeStartTime,
            resetAvailability: 0, resetAvailabilityWarMark: "1天只能领取一次使用码")
        useCodeLoaded = true
    }

    /// Android MainViewModel.generateUseCode：候选码不改变当前生效码。
    func generateUseCode() async throws -> GeneratedUseCode {
        guard sessionIsCurrent else { throw CancellationError() }
        if let reason = useCodeBlockReason { throw ApiError.transport(reason) }
        let raw = try await ApiClient.post("/account/useCode/new/generate", form: [:], tag: "generateUseCode")
        guard sessionIsCurrent else { throw CancellationError() }
        let response = try ApiClient.decode(GeneratedUseCode.self, from: raw, path: "generateUseCode")
        guard let result = response.data, let code = result.useCode, !code.isEmpty else {
            throw ApiError.transport("换码失败，请重试")
        }
        useCodeRemaining = max(0, result.remainTimes ?? 0)
        useCodeQuotaDate = Date()
        UseCodeQuotaStore.save(owner: profileOwner, remaining: useCodeRemaining ?? 0)
        return result
    }

    /// 先确认领取成功，再后台刷新资格和启用状态；刷新失败保留已确认的新码。
    func claimUseCode(_ code: String) async throws {
        guard sessionIsCurrent else { throw CancellationError() }
        guard !code.isEmpty else { throw ApiError.transport("领取失败，请重试") }
        let raw = try await ApiClient.post("/account/useCode/new/set", form: ["useCode": code], tag: "setUseCode")
        guard sessionIsCurrent else { throw CancellationError() }
        _ = try ApiClient.decode(EmptyData.self, from: raw, path: "setUseCode")
        acceptUseCode(code)
        let pending = useCodeTask
        Task { @MainActor in
            // 旧查询即使稍后返回，也不能用领取前的码覆盖本次已确认结果。
            if let pending { _ = await pending.value }
            guard self.sessionIsCurrent else { return }
            _ = await self.loadUseCode(force: true)
        }
    }

    func loadIfNeeded() async {
        guard !billsRefreshed else { return }
        await reload()
    }

    /// 查台账。已经有结果就直接返回，不重复请求。
    ///
    /// ⚠️ 每台设备**每轮扫描只查一次**（对照 Android `addDevice` 的注释）：
    /// 扫描回调对同一台设备每 ~200ms 就来一条，不收敛的话查不到的设备会被无限重查
    /// （Android 实测日志里 13 秒对同一个 MAC 发了 35 次）。
    /// 直接写入一份台账结果（扫码绑定等已经拿到 DeviceInfo 的场景）
    func putDeviceInfo(_ info: DeviceInfo, sn: String) {
        guard sessionIsCurrent else { return }
        deviceLookupMessages[sn] = nil
        deviceInfos[sn] = info
        if let ledgerSN = info.snCode, !ledgerSN.isEmpty { deviceInfos[ledgerSN] = info }
    }

    func deviceInfo(_ sn: String) async {
        guard sessionIsCurrent, !sn.isEmpty else { return }
        if deviceInfos[sn] != nil { return }
        if resolving.contains(sn) { return }
        if let retry = retryAfter[sn], retry > Date() { return }
        resolving.insert(sn)
        defer { resolving.remove(sn) }

        do {
            let info = try await DeviceLookup.load(sn)
            guard sessionIsCurrent else { return }
            if let info {
                putDeviceInfo(info, sn: sn)
            } else {
                deviceLookupMessages[sn] = "服务端没有这台设备的记录（\(sn)）"
                retryAfter[sn] = Date().addingTimeInterval(60)
                AppLog.shared.w("台账查不到 \(sn)（success=true 但 data 为空）")
            }
        } catch {
            guard sessionIsCurrent else { return }
            let message = LoginFeedback.message(error)
            deviceLookupMessages[sn] = message.contains("网络") ? message : "获取设备信息失败，请稍后重试"
            if case let ApiError.business(_, reason) = error { deviceLookupMessages[sn] = reason }
            retryAfter[sn] = Date().addingTimeInterval(10)
            AppLog.shared.w("台账请求失败 \(sn)：\(error.localizedDescription)")
        }
    }

    /// 显式刷新（下拉 / 结算完成后刷新账单）
    func reload() async {
        guard sessionIsCurrent else { return }
        if let billsTask { await billsTask.value; return }
        loading = true
        let task = Task { @MainActor in
            defer { self.loading = false; self.billsTask = nil }
            self.billsError = nil
            await BillService.refreshBalances()
            guard self.sessionIsCurrent else { return }
            do {
                let result = try await BillService.loadHistoryChecked()
                try Task.checkCancellation()
                guard self.sessionIsCurrent else { return }
                self.bills = result
                self.loaded = true
                self.billsRefreshed = true
                BillHistoryCache.save(result, owner: self.profileOwner)
                self.onBillsLoaded?(result)
            } catch {
                guard self.sessionIsCurrent else { return }
                self.billsError = "获取账单失败，请重试"
                AppLog.shared.w("账单刷新失败，保留已有数据：\(error.localizedDescription)")
            }
        }
        billsTask = task
        await task.value
    }

    func cancelRequests() {
        // 与 Android sessionJob.cancel 一致：旧实例不允许再发请求或接受回调。
        requestsCancelled = true
        billsTask?.cancel()
        profileTask?.cancel()
        useCodeTask?.cancel()
    }

    /// 系统页面遮盖不等于退出；只在原登录已失效时销毁共享缓存任务。
    func cancelRequestsIfSessionEnded() {
        if !sessionIsCurrent { cancelRequests() }
    }
}
