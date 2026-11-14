import Foundation

/// 「这一单花了多少钱」的查询与回退 —— 逐条对照 Android 的 `data/SettlementEngine.kt`。
///
/// ## 三态，不能只用 `Double?`
///
/// | 状态 | 含义 | 界面 |
/// |---|---|---|
/// | `.found(x)` | 拿到了大于 0 的金额 | 「本次消费 ¥x」 |
/// | `.knownZero` | 接口明确说 `consumeMoney` 就是 0 | 还要再确认，见下 |
/// | `.unknown` | 没拿到（网络失败 / 还没结算 / 结构不认识） | 「结算中」 |
///
/// 「字段不存在」和「字段就是 0」是**两件不同的事**：前者是「还不知道，继续等」，
/// 后者是「确实没花钱，可以收工」。用一个 `nil` 合并掉的话，
/// 开完水马上停的单子会一直停在「结算中」。
enum SettlementEngine {

    // MARK: - 对外

    /// 查出本次消费金额。
    ///
    /// - Returns: 金额（元）。`0.0` = 确实没花钱；`nil` = **还没查出来**（和 0 不是一回事）
    @MainActor static func settleAmount(
        orderNo: String,
        startTimeMs: Int64,
        snCode: String,
        deviceName: String = ""
    ) async -> Double? {
        let generation = SessionWork.generation ?? Session.shared.requestGeneration
        guard SessionWork.isCurrent(generation) else { return nil }
        var sawDefiniteZero = false

        if !orderNo.isEmpty {
            // ① 快速探测：命中正数立刻收工。
            //    实测（Android 27 次调用）第 1 轮就是终值，不能让有消费的单子干等。
            probe: for attempt in 0 ..< probeRounds {
                guard SessionWork.isCurrent(generation) else { return nil }
                let result = await queryConsumeResult(orderNo: orderNo, snCode: snCode)
                guard SessionWork.isCurrent(generation) else { return nil }
                switch result {
                case let .found(v):
                    Prefs.recordConsume(snCode, amount: v)
                    PendingSettlementStore.clear(snCode: snCode)
                    AppLog.shared.i("结算命中（consumeOrder/result，第 \(attempt + 1) 轮）：¥\(MoneyFormat.format(v))")
                    return v
                case .knownZero:
                    sawDefiniteZero = true
                    // 字段在、值是 0 —— 交给下面的零确认，别急着下结论
                    // （⚠️ 这里必须是 `break probe`：Swift 的裸 `break` 只跳出 switch）
                    break probe
                case .unknown:
                    break
                }
                if attempt < probeRounds - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(confirmDelayMs) * 1_000_000)
                }
            }

            // ② 零确认：拿到过 0 就多观察几轮再认。
            //
            // 直答接口在结算完成前 `consumeMoney` 就是 0，和服务端真算出 0 元**长得一模一样**。
            // 只问一两轮的话，服务端稍慢一点就每一轮都落在「还没算完」的窗口里，
            // 于是把「还没算完」当成「没花钱」。
            //
            // 代价是零消费的单子多等几秒；这个交换划算 ——
            // **「明明花了钱却被告知无消费」比多等几秒严重得多**。
            if sawDefiniteZero {
                for attempt in 0 ..< zeroConfirmRounds {
                    try? await Task.sleep(nanoseconds: UInt64(zeroConfirmDelayMs) * 1_000_000)
                    guard SessionWork.isCurrent(generation) else { return nil }
                    let zeroProbe = await queryConsumeResult(orderNo: orderNo, snCode: snCode)
                    guard SessionWork.isCurrent(generation) else { return nil }
                    if case let .found(v) = zeroProbe {
                        Prefs.recordConsume(snCode, amount: v)
                        PendingSettlementStore.clear(snCode: snCode)
                        AppLog.shared.i("结算命中（零确认第 \(attempt + 1) 轮）：¥\(MoneyFormat.format(v))")
                        return v
                    }
                }
            }
            AppLog.shared.w("consumeOrder/result 没给金额（见过明确的 0：\(sawDefiniteZero)），回退到账单列表")
        }

        // ③ 回退：拉账单列表自己匹配
        guard SessionWork.isCurrent(generation) else { return nil }
        let probe = await settleFromBillList(orderNo: orderNo, startTimeMs: startTimeMs, snCode: snCode, generation: generation)
        guard SessionWork.isCurrent(generation) else { return nil }

        // 账单列表也没查到金额时，要靠**两种不同的信息**下结论：
        //
        // | 直答接口 | 账单列表里有没有这一单 | 结论 |
        // |---|---|---|
        // | 说 0 | **有**（金额还没填） | 未结算完 → nil（「结算中」） |
        // | 说 0 | **从来没有** | 真零消费 → 0.0（「无消费」） |
        // | 说不清 | 有没有都行 | 未知 → nil |
        //
        // 第二行是关键：真零消费的单子账单列表里压根不会有这一条（开完水马上停，
        // 一笔账都不产生）。所以「账单里出现过」本身就是**有消费**的证据，
        // 不能因为金额还是 0 就判成没花钱 —— 这正是「有消费却显示无消费」的来源。
        let resolved: Double?
        if let amount = probe.amount {
            resolved = amount
        } else if probe.sawBill {
            resolved = nil
        } else if sawDefiniteZero {
            resolved = 0.0
        } else {
            resolved = nil
        }
        if probe.sawBill && probe.amount == nil {
            AppLog.shared.w("结算：账单已出现但金额未填，按「未结算完」处理（不判无消费）")
        }

        // 待对账登记：**只要不是铁板钉钉的金额**就留一条记录。
        //
        // 那个靠 `sawDefiniteZero` 推断出来的 0.0 也一样 —— 它是「接口说 0 + 账单从未出现」，
        // 已是最可信的零消费判据，但仍然是推断（万一账单生成得特别慢）。
        // 登记之后拿账单列表复核：复核到就补金额，复核不到就维持原判。
        let needsReconcile = resolved == nil || (resolved == 0.0 && sawDefiniteZero)
        if needsReconcile {
            PendingSettlementStore.record(PendingSettlement(
                snCode: snCode,
                orderNo: orderNo,
                startedAt: startTimeMs,
                deviceName: deviceName,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000),
                elapsedSec: startTimeMs > 0
                    ? Int((Int64(Date().timeIntervalSince1970 * 1000) - startTimeMs) / 1000)
                    : 0
            ))
            if resolved == 0.0 {
                AppLog.shared.w("结算：接口说 0 且账单从未出现，按真零消费处理，同时留一条待对账")
            }
        } else {
            PendingSettlementStore.clear(snCode: snCode)
        }
        return resolved
    }

    // MARK: - 主路径：直接问这一单结了多少钱

    /// 上一次记进日志的原始响应体。只在**变了**的时候再记，避免多轮刷屏
    private static var lastRawLogged: String?

    /// `/order/consumeOrder/result/query`
    ///
    /// ⚠️ 这里故意走**原始 JSON 串**而不是 `Decodable` 模型：
    /// 不同学校的字段名/类型不一样（`consumeMoney` 有数字也有字符串），
    /// 声明成固定模型会一解码就失败，然后整条主路径静默失效。
    /// Android 端也是同样的理由（`consumeOrderResultRaw`）。
    private static func queryConsumeResult(orderNo: String, snCode: String) async -> MoneyProbe {
        do {
            let data = try await ApiClient.post(
                "/order/consumeOrder/result/query",
                form: ["snCode": snCode, "orderNo": orderNo],
                tag: "consumeResult"
            )
            let raw = String(data: data, encoding: .utf8) ?? ""
            if raw != lastRawLogged {
                lastRawLogged = raw
                AppLog.shared.i("结算原始响应 consumeOrder/result/query: \(raw)")
            }
            return probeMoney(raw)
        } catch {
            return .unknown
        }
    }

    /// 从响应 JSON 里挖出消费金额并**换算成元**。
    ///
    /// 1. 先认已知字段名（数字/字符串两种都收）
    /// 2. 认不出来就在 `data` 里按名字找像金额的数值字段
    ///
    /// ⚠️ 第 2 步必须**排除余额类字段**（`balance` / `account` / `wallet` / `pre` / `give` /
    /// `remain`）。拿钱包余额当消费金额是这里最危险的错法：金额会大得离谱，
    /// 而且看着还挺像个正常数字，不会有人发现不对。
    ///
    /// ⚠️ 单位是**厘**，必须过一遍 `toYuan`。
    /// ⚠️ 故意做成 internal：回归检查要直接喂各种学校的响应形状给它
    static func probeMoney(_ raw: String) -> MoneyProbe {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }

        // 金额可能在 data 里，也可能直接铺在顶层，两处都看
        var scopes: [[String: Any]] = []
        if let d = root["data"] as? [String: Any] { scopes.append(d) }
        scopes.append(root)

        // ① 已知字段名。字段**在**就采信，哪怕值是 0
        for scope in scopes {
            for key in ["consumeMoney", "consumeMoneyStr", "money", "consumeAmount"] {
                guard let el = scope[key], !(el is NSNull) else { continue }
                guard let rawValue = numberValue(el) else { continue }
                let v = toYuan(rawValue)
                if v > 0 {
                    AppLog.shared.i("结算：`\(key)` 原始值 \(rawValue) → ¥\(v)（按 1000 厘/元 换算）")
                    return .found(v)
                }
                return .knownZero
            }
        }

        // ② 兜底：按名字找像金额的数值字段。
        // ⚠️ 这里**只认正数** —— 字段名是猜的，猜出来的 0 不敢当「确实没花钱」用，
        // 宁可算 unknown 让它走账单列表那条路复核一遍。
        for scope in scopes {
            for (key, el) in scope {
                let k = key.lowercased()
                guard k.range(of: amountKeyHint, options: .regularExpression) != nil,
                      k.range(of: amountKeyExclude, options: .regularExpression) == nil,
                      let rawValue = numberValue(el)
                else { continue }
                let v = toYuan(rawValue)
                if v > 0 {
                    AppLog.shared.w("结算：字段名不在预期内，按名字兜底命中 `\(key)` = \(rawValue)（原始值）→ ¥\(v)")
                    return .found(v)
                }
            }
        }

        if (root["success"] as? Bool) == true, root["data"] is NSNull || root["data"] == nil {
            AppLog.shared.i("结算：接口返回成功但 data 为空，这单可能还没结算")
        }
        return .unknown
    }

    private static func numberValue(_ el: Any) -> Double? {
        if let d = el as? Double { return d }
        if let i = el as? Int { return Double(i) }
        if let n = el as? NSNumber { return n.doubleValue }
        if let s = el as? String { return Double(s) }
        return nil
    }

    // MARK: - 回退路径：账单列表

    private struct BillProbe {
        /// 查到的金额（元）；没查到为 nil
        let amount: Double?
        /// 账单列表里**是否出现过这一单**（哪怕金额还是占位 `"0.0"`）。
        /// 这是「有消费」的直接证据：真零消费的单子压根不会产生账单。
        let sawBill: Bool
    }

    @MainActor private static func settleFromBillList(
        orderNo: String,
        startTimeMs: Int64,
        snCode: String,
        generation: UUID
    ) async -> BillProbe {
        let month = currentMonth()

        // ⚠️ 兜底时间窗必须**往前放宽**，不能拿 `>= startTimeMs` 卡。
        //
        // 账单里的 `consumeDate` 是**下单那一刻**（发 downRate 的时候），
        // 而 `startTimeMs` 是**开阀确认成功之后**才写的 —— 开阀要轮询一两轮才确认，
        // 天然晚 1~2 秒。用 `>=` 判就把这一单自己滤掉了。
        let windowStart = startTimeMs > 0 ? startTimeMs - windowSlackMs : 0

        var sawBill = false

        for attempt in 0 ..< billListRounds {
            guard SessionWork.isCurrent(generation) else { return BillProbe(amount: nil, sawBill: sawBill) }
            if let bills = await fetchBills(month: month) {
                guard SessionWork.isCurrent(generation) else { return BillProbe(amount: nil, sawBill: sawBill) }
                if let matched = matchBill(bills: bills, orderNo: orderNo, windowStartMs: windowStart) {
                    sawBill = true
                    // ⚠️ 账单里的 `consumeMoney` 是**字符串**、单位是**元**
                    // （和主路径那个数字型的差 1000 倍）
                    if let m = matched.yuan, m > 0 {
                        Prefs.recordConsume(snCode, amount: m)
                        AppLog.shared.i("结算命中（账单列表，第 \(attempt + 1) 轮）：orderNo=\(matched.orderNo ?? "") 金额=\(m) 时间=\(matched.consumeDate ?? "")")
                        return BillProbe(amount: m, sawBill: true)
                    }
                    // 账单先以 "0.0" 占位出现、结算完才填金额，
                    // 所以这里不能拿 0 当结论，只能记下「见到过账单」继续下一轮
                    AppLog.shared.i("结算：已匹配到账单但金额还是 \(matched.consumeMoney ?? "空")（可能是占位值）")
                }
            }
            if attempt < billListRounds - 1 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }

        AppLog.shared.w("结算超时：orderNo=\(orderNo) 两条路都没拿到金额（sawBill=\(sawBill)）")

        // ⚠️ **一律返回 nil（"还没确定"），不要返回 0.0**。
        // 「账单里匹配到了这一单」本身就是「有消费」的证据，只是金额还没填上。
        return BillProbe(amount: nil, sawBill: sawBill)
    }

    /// 拉一个月的账单；网络/解析失败返回 nil（**空数组和失败必须分开**）
    private static func fetchBills(month: String) async -> [BillDTO]? {
        do {
            let data = try await ApiClient.get(
                "/order/query/account/bill/list",
                query: ["month": month, "billRequestType": "2"],
                tag: "billListForSettle"
            )
            let resp = try ApiClient.decodeShell([BillItem].self, from: data, path: "billListForSettle")
            guard resp.success else { return nil }
            return (resp.data ?? []).compactMap { $0.consumeBillDTO }
        } catch {
            return nil
        }
    }

    /// 从账单列表里找出「本次这一单」。
    ///
    /// - `orderNo`（20 位）才是**关阀时用的那个**，先拿它精确匹配
    /// - `orderId`（7 位）是账单**序号**，只作兜底（万一某校真用同一个值）
    /// - 都对不上才退回时间窗，且窗口要**往前放宽**
    private static func matchBill(bills: [BillDTO], orderNo: String, windowStartMs: Int64) -> BillDTO? {
        if !orderNo.isEmpty {
            if let hit = bills.first(where: { $0.orderNo == orderNo }) { return hit }
            if let hit = bills.first(where: { $0.orderId == orderNo }) { return hit }
        }
        let candidates = bills.filter { bill in
            // 没有开阀时间就**没法判断哪笔是本次的**，一笔都不能算
            // （写 `return true` 的话会把所有历史账单都当成本次的，
            //  于是出现「用时 0 秒 · 消费 ¥上一次的金额」）
            guard windowStartMs > 0 else { return false }
            return Int64(BalanceEstimator.billTimeMs(bill.consumeDate ?? "")) >= windowStartMs
        }
        return candidates.max { a, b in
            (a.consumeDate ?? "") < (b.consumeDate ?? "")
        }
    }

    private static func currentMonth() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM"
        return fmt.string(from: Date())
    }

    // MARK: - 常量（与 Android 完全一致）

    /// 主路径问几轮。实测第 1 轮就是最终值，两轮足够（第二轮只在拿到 0 时用）
    private static let probeRounds = 2
    private static let confirmDelayMs = 1000

    /// 拿到 0 之后的额外确认轮数。
    ///
    /// ⚠️ 别再往上加。曾经加到 6 轮（7.2 秒）是治错了病：
    /// 误判的根因是**判据**（账单出现过 ⇒ 有消费），不是等得不够长。
    private static let zeroConfirmRounds = 2
    private static let zeroConfirmDelayMs = 1200

    /// 回退路径问几轮。⚠️ **不能是 1**：账单会先以占位 `"0.0"` 出现，
    /// 只问一轮就会把「刚出现还没填金额」误判成无消费。
    private static let billListRounds = 3

    private static let windowSlackMs: Int64 = 3 * 60 * 1000

    private static let amountKeyHint = "(consume|money|amount|fee|cost|pay|charge|price)"
    private static let amountKeyExclude =
        "(balance|remain|surplus|account|wallet|pre|give|given|total|sum|count|id|no\\b|time|date|status|state)"

    /// 厘 → 元。`/order/consumeOrder/result/query` 的单位是**厘**（1 元 = 1000 厘），
    /// 而账单列表里同名字段是**元**。忘了换算不是报错，而是静默错 1000 倍。
    private static func toYuan(_ raw: Double) -> Double { raw / 1000.0 }
}

/// 三态探询结果
enum MoneyProbe {
    case found(Double)
    case knownZero
    case unknown
}
