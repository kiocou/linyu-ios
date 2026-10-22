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

    /// 进程内只自动加载一次；之后只有用户下拉刷新才会再请求
    private var didAutoLoad = false

    func loadIfNeeded() async {
        guard !didAutoLoad else { return }
        didAutoLoad = true
        await reload()
    }

    /// 显式刷新（下拉 / 结算完成后刷新账单）
    func reload() async {
        if loading { return }
        loading = true
        defer { loading = false }

        // 真实余额（一卡通 / 钱包）只在这里和首页各拉一次；
        // 漏了这一页，先进账单页会一直按「估算」渲染
        await BillService.refreshBalances()
        bills = await BillService.loadHistory()
        loaded = true
    }
}
