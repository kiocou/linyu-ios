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
    private var billsTask: Task<Void, Never>?

    func loadProfileIfNeeded() async {
        guard !profileLoaded else { return }
        if let profileTask { await profileTask.value; return }
        let task = Task { @MainActor in
            defer { self.profileTask = nil }
            self.profileError = nil
            async let account = BillService.loadAccountInfo()
            async let project = BillService.loadProjectInfo()
            let (accountResult, projectResult) = await (account, project)
            guard !Task.isCancelled else { return }
            guard let accountResult, let projectResult else {
                self.profileError = "获取个人信息失败，请重试"
                return
            }
            self.accountInfo = accountResult
            self.projectName = projectResult.projectName ?? ""
            self.profileLoaded = true
        }
        profileTask = task
        await task.value
    }

    @discardableResult
    func loadUseCode(force: Bool = false) async -> Bool {
        if let useCodeTask { return await useCodeTask.value }
        if !force && useCodeLoaded { return true }
        let task = Task { @MainActor in
            defer { self.useCodeTask = nil }
            do {
                let raw = try await ApiClient.get("/account/useCode/new", tag: "useCode")
                let result = try ApiClient.decode(UseCodeData.self, from: raw, path: "useCode").data
                try Task.checkCancellation()
                self.useCode = result
                self.useCodeLoaded = true
                return true
            } catch {
                AppLog.shared.w("使用码加载失败：\(error.localizedDescription)")
                return false
            }
        }
        useCodeTask = task
        return await task.value
    }

    func setUseCodeEnabled(_ enabled: Bool) async throws {
        guard !changingUseCodeStatus else { return }
        changingUseCodeStatus = true
        defer { changingUseCodeStatus = false }
        let raw = try await ApiClient.post("/account/useCode/new/status/update",
            form: ["useCodeStatus": enabled ? "1" : "0"], tag: "useCodeStatus")
        _ = try ApiClient.decode(EmptyData.self, from: raw, path: "useCodeStatus")
        useCode?.useCodeStatus = enabled ? 1 : 0
    }

    func acceptUseCode(_ code: String) {
        useCode = UseCodeData(useCode: code, useCodeStatus: useCode?.useCodeStatus,
            useCodeRandom: useCode?.useCodeRandom, useCodeStartTime: useCode?.useCodeStartTime,
            resetAvailability: 0, resetAvailabilityWarMark: "1天只能领取一次使用码")
        useCodeLoaded = true
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        await reload()
    }

    /// 查台账。已经有结果就直接返回，不重复请求。
    ///
    /// ⚠️ 每台设备**每轮扫描只查一次**（对照 Android `addDevice` 的注释）：
    /// 扫描回调对同一台设备每 ~200ms 就来一条，不收敛的话查不到的设备会被无限重查
    /// （Android 实测日志里 13 秒对同一个 MAC 发了 35 次）。
    /// 直接写入一份台账结果（扫码绑定等已经拿到 DeviceInfo 的场景）
    func putDeviceInfo(_ info: DeviceInfo, sn: String) {
        deviceInfos[sn] = info
    }

    func deviceInfo(_ sn: String) async {
        guard !sn.isEmpty else { return }
        if deviceInfos[sn] != nil { return }
        if resolving.contains(sn) { return }
        if let retry = retryAfter[sn], retry > Date() { return }
        resolving.insert(sn)
        defer { resolving.remove(sn) }

        do {
            let data = try await ApiClient.get(
                "/device/info/mac",
                query: ["macAddress": sn],
                tag: "deviceInfo"
            )
            let resp = try ApiClient.decode(DeviceInfo.self, from: data, path: "deviceInfo")
            if resp.success, let info = resp.data {
                deviceInfos[sn] = info
            } else {
                retryAfter[sn] = Date().addingTimeInterval(60)
                AppLog.shared.w("台账查不到 \(sn)（success=true 但 data 为空）")
            }
        } catch {
            retryAfter[sn] = Date().addingTimeInterval(10)
            AppLog.shared.w("台账请求失败 \(sn)：\(error.localizedDescription)")
        }
    }

    /// 显式刷新（下拉 / 结算完成后刷新账单）
    func reload() async {
        if let billsTask { await billsTask.value; return }
        loading = true
        let task = Task { @MainActor in
            defer { self.loading = false; self.billsTask = nil }
            self.billsError = nil
            await BillService.refreshBalances()
            do {
                let result = try await BillService.loadHistoryChecked()
                try Task.checkCancellation()
                self.bills = result
                self.loaded = true
            } catch {
                guard !Task.isCancelled else { return }
                self.billsError = "获取账单失败，请重试"
                AppLog.shared.w("账单刷新失败，保留已有数据：\(error.localizedDescription)")
            }
        }
        billsTask = task
        await task.value
    }

    func cancelRequests() {
        billsTask?.cancel()
        profileTask?.cancel()
        useCodeTask?.cancel()
    }
}
