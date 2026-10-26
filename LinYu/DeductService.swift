import Foundation
import Combine

/// 单笔代扣的结果 —— 逐条对照 Android `MainViewModel.DeductResult`。
///
/// ## 为什么「失败」和「结果未知」必须分开
///
/// 分不清的代价很实在：请求已经发到服务端、只是没拿到答复时，如果报「失败」，
/// 界面就会把按钮放回去让用户重试 —— 而服务端可能**已经扣过了**，
/// 那一下就是**扣两次**。
///
/// 所以 `unknown` 既不能说成功也不能说失败，只能重新查一次服务端来定夺。
enum DeductResult {
    case ok(consumeDate: String)
    /// 服务端**明确**说没成（余额不足、账户异常…），可以放心重试
    case failed(consumeDate: String, reason: String?)
    /// 请求发出去了但没拿到答复（超时、断连、取消）。**不能当成失败**
    case unknown(consumeDate: String)
}

/// 批量补扣的汇总
struct DeductSummary {
    let ok: Int
    let failed: Int
    /// 结果未知的笔数 —— 这些既不能说成功也不能说失败
    let unknown: Int
    /// 第一笔失败时服务端给的原文（「余额不足」之类）
    let firstFailReason: String?
}

/// 未支付账单（残留账单）+ 手动代扣 —— 逐条对照 Android
/// `MainViewModel.loadUnpaidBills / requestDeduct / deductAllUnpaid`。
///
/// ⚠️ 这是**动钱**的一层，三条约束不能松：
///
/// 1. **防重**：并发点两下只能扣一次。`deductingConsumeDate` 非 nil 期间一律拒绝，
///    而且必须回调告知被挡住（静默返回的话调用方已经关了弹窗，用户以为在扣）。
/// 2. **失败不清列表**：拉取失败就保持原样，否则按钮会凭空消失。
/// 3. **结果未知要复核**：扣完重新拉一次未支付列表，账单还在 = 没扣成，
///    不在了 = 扣成了。这是唯一能确定答案的办法，不能靠猜。
@MainActor
final class DeductService: ObservableObject {
    private let generation = Session.shared.requestGeneration
    private var stopped = false
    private var isCurrent: Bool { !stopped && SessionWork.isCurrent(generation) }

    /// 未支付账单列表。界面靠它决定哪些账单显示「请求代扣」按钮
    @Published private(set) var bills: [UnpaidBill] = []
    /// 正在代扣的那条账单的 `consumeDate`；非空期间按钮禁用，防止连点重复扣款
    @Published private(set) var deductingConsumeDate: String?

    /// 请求序号：只接受**最新一次**请求的结果。
    ///
    /// 刷新入口有四个（钱包页进入、下拉刷新、主页下拉、代扣成功后），
    /// 没有它的话，一个还在路上的旧响应回来后会把新结果覆盖掉 ——
    /// 表现为「刚扣完，按钮又出现了」。
    private var seq = 0

    static let busyMessage = "正在处理另一笔代扣，请稍候"

    // MARK: - 派生

    /// 能代扣的账单：`consumeDate` 为空的一笔根本发不出去（接口靠它定位）
    var deductibleBills: [UnpaidBill] {
        bills.filter { !($0.consumeDate ?? "").isEmpty }
    }

    /// 未支付账单的 `consumeDate` 集合 —— 按账单列表匹配按钮显隐时用它
    var unpaidConsumeDates: Set<String> {
        Set(deductibleBills.compactMap { $0.consumeDate })
    }

    // MARK: - 拉取

    /// 拉一次未支付列表；失败返回 nil（调用方保持原样，不清空）
    private func fetch() async -> [UnpaidBill]? {
        guard isCurrent else { return nil }
        let result = await BillService.loadUnpaid()
        return isCurrent ? result : nil
    }

    /// 拉未支付账单列表。**失败保持原样，不清空** —— 清空会让按钮凭空消失
    func load() async {
        guard isCurrent else { return }
        seq += 1
        let mine = seq
        guard let list = await fetch() else { return }
        guard mine == seq else { return }
        bills = list
    }

    /// 「结果未知」的收尾：重查一次服务端，以它为准
    private func reconcile() async -> [UnpaidBill]? {
        guard let list = await fetch() else { return nil }
        // 让更早发出的刷新全部作废 —— 这份是**刚刚**拿到的，比它们都新
        seq += 1
        bills = list
        return list
    }

    // MARK: - 代扣

    /// 扣一笔。**这是唯一碰代扣接口的地方**，单笔和批量都走它。
    ///
    /// ⚠️ 两条和本项目其他接口**都不一样**，照抄别的写法会失败：
    /// 1. **body 是 JSON**，其他全是 form-urlencoded
    /// 2. **账单用 `consumeDate` 定位**，不是 orderNo
    ///
    /// ⚠️ `phoneSystem` 传 `WeChat` 是**照抄抓包**的：这个接口是官方 App 里那个 H5
    /// 页面调的，和原生请求（`phoneSystem=android`）不是一条路。
    private func deductOnce(_ consumeDate: String) async -> DeductResult {
        guard isCurrent else { return .unknown(consumeDate: consumeDate) }
        guard !consumeDate.isEmpty else {
            return .failed(consumeDate: consumeDate, reason: "账单信息不完整")
        }
        let session = Session.shared
        let body: [String: Any] = [
            "deductType": 7,          // 抓包实测值，只有一个样本
            "consumeDate": consumeDate,
            "projectId": session.projectId,
            "accountId": session.accountId,
            "loginCode": session.loginCode,
            "userId": session.userId,
            "phoneSystem": "WeChat",
        ]
        do {
            let data = try await ApiClient.postJSON(
                "/order/thirdTrade/single/json/pay",
                body: body,
                tag: "deduct"
            )
            let resp = try ApiClient.decodeShell(EmptyData.self, from: data, path: "deduct")
            guard isCurrent else { return .unknown(consumeDate: consumeDate) }
            if resp.success {
                AppLog.shared.i("代扣成功：\(consumeDate)")
                return .ok(consumeDate: consumeDate)
            }
            AppLog.shared.w("代扣被拒：\(resp.displayMessage ?? "")（\(resp.errorCode ?? -1)）")
            return .failed(consumeDate: consumeDate, reason: resp.displayMessage)
        } catch {
            // ⚠️ 超时 / 断连 / 取消：请求**可能已经到达服务端**，不能当作失败
            AppLog.shared.w("代扣结果未知：\(error.localizedDescription)")
            return .unknown(consumeDate: consumeDate)
        }
    }

    /// 手动请求代扣（单笔）
    func requestDeduct(consumeDate: String) async -> DeductResult {
        guard isCurrent else { return .unknown(consumeDate: consumeDate) }
        guard !consumeDate.isEmpty else {
            return .failed(consumeDate: consumeDate, reason: "账单信息不完整")
        }
        // ⑧ 不能静默返回 —— 调用方已经关了弹窗，用户会以为在扣
        guard deductingConsumeDate == nil else {
            return .failed(consumeDate: consumeDate, reason: Self.busyMessage)
        }

        deductingConsumeDate = consumeDate
        defer { deductingConsumeDate = nil }

        let result = await deductOnce(consumeDate)
        guard isCurrent else { return .unknown(consumeDate: consumeDate) }
        switch result {
        case .ok:
            // 成功后立刻把这条从列表里摘掉，不等网络往返
            bills.removeAll { $0.consumeDate == consumeDate }
            await load()
            if isCurrent { onBillsChanged?() }
        case .unknown:
            if await reconcile() == nil { await load() }
        case .failed:
            break
        }
        return result
    }

    /// 补扣**全部**未支付账单，一笔一笔来。
    ///
    /// 开阀被未扣账单卡住时用这个：只补一笔往往还是开不了阀，
    /// 而让用户回「钱包」页一笔一笔点太绕。
    ///
    /// - Returns: nil 表示**一笔都没发出去**（没有可补的，或已被另一个代扣挡住）
    func deductAll() async -> DeductSummary? {
        guard isCurrent else { return nil }
        guard deductingConsumeDate == nil else { return nil }
        let dates = deductibleBills.compactMap { $0.consumeDate }
        guard !dates.isEmpty else { return nil }

        // 同步置锁，和 requestDeduct 一致
        deductingConsumeDate = dates[0]
        defer { deductingConsumeDate = nil }

        var ok = 0, failed = 0, unknown = 0
        var failReason: String?

        for date in dates {
            guard isCurrent else { return nil }
            deductingConsumeDate = date
            let result = await deductOnce(date)
            guard isCurrent else { return nil }
            switch result {
            case .ok:
                ok += 1
                bills.removeAll { $0.consumeDate == date }
            case let .failed(_, reason):
                failed += 1
                if failReason == nil { failReason = reason }
            case .unknown:
                unknown += 1
            }
        }

        // 有未知的才需要重查；全部明确成功时直接刷新即可
        if unknown > 0 {
            if await reconcile() == nil { await load() }
        } else {
            await load()
        }
        if isCurrent { onBillsChanged?() }

        return DeductSummary(ok: ok, failed: failed, unknown: unknown, firstFailReason: failReason)
    }

    /// 扣款成功/复核后要刷新账单页 —— 由容器注入（这一层不该知道谁在展示账单）
    var onBillsChanged: (() -> Void)?

    /// 退出登录 / 挤号时清掉（账单和代扣锁都是跟账号走的）
    func reset() {
        stopped = true
        bills = []
        deductingConsumeDate = nil
        seq += 1
    }
}
