import Foundation

/// 账单 / 钱包 / 学籍信息 —— 对照 Android 的 `MainViewModel.loadBills/loadWallet/loadAccountInfo`。
enum BillService {

    /// 拉**最近 3 个月**的账单并合并。
    ///
    /// 为什么要 3 个月：账单列表接口一个月一拉，只拉当月的话
    /// 月初打开 App 会看到空列表（像是「没消费过」），而消费趋势里 7 天视图也会缺数据。
    /// Android 那边同样拉 3 个月（`for (i in 0..2)`）。
    static func loadHistory() async -> [BillDTO] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM"

        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")

        var all: [BillDTO] = []
        for i in 0 ..< 3 {
            let month = fmt.string(from: Date().addingTimeInterval(TimeInterval(-i) * 30 * 24 * 3600))
            if let list = try? await loadMonth(month) {
                all.append(contentsOf: list)
            }
        }
        AppLog.shared.i("账单：拉取 \(all.count) 条（最近 3 个月）")
        return all
    }

    /// 单月账单。`billRequestType=2` 是 Android 用的固定值。
    static func loadMonth(_ month: String) async throws -> [BillDTO] {
        let data = try await ApiClient.get(
            "/order/query/account/bill/list",
            query: ["month": month, "billRequestType": "2"],
            tag: "bills"
        )
        let resp = try ApiClient.decode([BillItem].self, from: data, path: "billList")
        guard resp.success else { return [] }
        return (resp.data ?? []).compactMap { $0.consumeBillDTO }
    }

    /// 在最近的账单里找某一单（结算的兜底路径）
    static func findBill(orderNo: String, snCode: String) async -> BillDTO? {
        let all = await loadHistory()
        if !orderNo.isEmpty, let hit = all.first(where: { $0.orderNo == orderNo }) {
            return hit
        }
        if !snCode.isEmpty, let hit = all.first(where: { $0.deviceSnCode == snCode }) {
            return hit
        }
        return nil
    }

    // MARK: - 钱包 / 一卡通

    /// GET + 解码，失败返回 nil（这些接口失败都不该打断页面）
    private static func fetch<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [String: String] = [:],
        tag: String
    ) async -> APIResponse<T>? {
        do {
            let data = try await ApiClient.get(path, query: query, tag: tag)
            let resp = try ApiClient.decode(type, from: data, path: path)
            return resp.success ? resp : nil
        } catch {
            AppLog.shared.w("\(path) 请求/解析失败：\(error.localizedDescription)")
            return nil
        }
    }

    static func loadWallet() async -> WalletData? {
        await fetch(WalletData.self, path: "/account/wallet", tag: "wallet")?.data
    }

    static func loadCampusInfo() async -> CampusUserInfo? {
        await fetch(CampusUserInfo.self, path: "/settlement/campus/userInfo", tag: "campus")?.data
    }

    static func loadAccountInfo() async -> AccountInfo? {
        await fetch(AccountInfo.self, path: "/account/info", tag: "accountInfo")?.data
    }

    static func loadProjectInfo() async -> ProjectInfo? {
        await fetch(ProjectInfo.self, path: "/project/info/triple", tag: "projectInfo")?.data
    }

    /// 把两个余额来源刷进 Prefs（界面读 Prefs，所以刷完要手动触发刷新）
    static func refreshBalances() async {
        if let c = await loadCampusInfo() {
            Prefs.campusBalance = c.amount ?? ""
            AppLog.shared.i("一卡通余额：\(c.amount ?? "空")")
        }
        if let w = await loadWallet() {
            Prefs.walletBalance = w.accountRealMoney ?? ""
            AppLog.shared.i("钱包余额：\(w.accountRealMoney ?? "空")")
        }
    }
}

// MARK: - 消费趋势统计

/// 逐条对照 Android 的 `data/SpendingAnalytics.kt`
enum SpendingAnalytics {

    enum Range: String, CaseIterable {
        case last7 = "LAST_7_DAYS"
        case thisMonth = "THIS_MONTH"

        var label: String { self == .last7 ? "7天" : "本月" }
    }

    struct DailySpend: Identifiable {
        let date: Date
        let amount: Double
        let count: Int
        var id: Date { date }
    }

    struct Summary {
        var points: [DailySpend] = []
        var total: Double = 0
        var count: Int = 0
        var average: Double = 0
    }

    static func summarize(bills: [BillDTO], range: Range, today: Date = Date()) -> Summary {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")

        let start: Date = {
            switch range {
            case .last7:
                return cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: today)) ?? today
            case .thisMonth:
                let comps = cal.dateComponents([.year, .month], from: today)
                return cal.date(from: comps) ?? today
            }
        }()

        // 按天聚合
        var byDay: [Date: (sum: Double, count: Int)] = [:]
        for b in bills {
            let ms = BalanceEstimator.billTimeMs(b.consumeDate ?? "")
            guard ms > 0 else { continue }
            let date = cal.startOfDay(for: Date(timeIntervalSince1970: ms / 1000))
            guard date >= start, date <= cal.startOfDay(for: today) else { continue }
            guard let amount = b.yuan, amount.isFinite, amount >= 0 else { continue }
            var cur = byDay[date] ?? (0, 0)
            cur.sum += amount
            cur.count += 1
            byDay[date] = cur
        }

        // 补全每一天（没消费的那天是 0，不是「不存在」——折线要连起来）
        var points: [DailySpend] = []
        var cursor = start
        let end = cal.startOfDay(for: today)
        while cursor <= end {
            let v = byDay[cursor] ?? (0, 0)
            points.append(DailySpend(date: cursor, amount: v.sum, count: v.count))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let total = points.reduce(0) { $0 + $1.amount }
        let count = points.reduce(0) { $0 + $1.count }
        return Summary(
            points: points,
            total: total,
            count: count,
            average: count == 0 ? 0 : total / Double(count)
        )
    }
}

/// 图表坐标策略 —— 对照 Android 的 `TrendDisplayPolicy`
enum TrendDisplayPolicy {

    static func plotX(index: Int, size: Int, width: CGFloat, horizontalInset: CGFloat) -> CGFloat {
        if size <= 1 { return width / 2 }
        let inset = min(max(horizontalInset, 0), width / 2)
        return inset + CGFloat(index) / CGFloat(size - 1) * (width - inset * 2)
    }

    /// 横轴最多 5 个标签
    static func axisIndices(size: Int, maxLabels: Int = 5) -> [Int] {
        if size <= 0 { return [] }
        if size <= maxLabels { return Array(Set([0, size / 2, size - 1])).sorted() }
        let step = Double(size - 1) / Double(maxLabels - 1)
        var out: [Int] = []
        for i in 0 ..< maxLabels {
            let v = Int(Double(i) * step)
            if !out.contains(v) { out.append(v) }
        }
        return out
    }
}
