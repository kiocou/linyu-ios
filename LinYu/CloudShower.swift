import Foundation

/// 云端（4G）通道 —— 对照 Android 的 `data/ShowerController.kt`。
///
/// ## 两条通道的差别
///
/// | | 云端 `tcpDevice/*` | 蓝牙 `bluetooth/*` |
/// |---|---|---|
/// | 谁下发指令 | 服务端推给设备（要求设备自带 4G） | **手机当网关**，阀由本机写进设备 |
/// | 关阀 | 服务端受理即算成功 | 必须 0x22 设备确认 |
/// | 结算 | 服务端自己算，App 只是查询 | App 采集 + 上传 |
///
/// 对蓝牙表调 `tcpDevice` 必然回 `306 设备不在线` —— 这是分流的意义。
enum CloudShower {

    // MARK: - 开阀

    enum OpenOutcome {
        /// 已成功开阀
        case opened(orderNo: String, consumeDate: String, autoDisCon: Int, preDeduct: Double?)
        /// 设备上本来就有订单（自己的），恢复它
        case resumed(orderNo: String, preDeduct: Double?)
        /// 别人正在用
        case inUseByOthers
        /// 服务端说设备不在线（306）→ 上层问用户要不要改用蓝牙
        case deviceOffline
        case failed(String)
    }

    /// 开阀。`budgetMs` 是轮询确认的总预算（Android 也是 6 秒）。
    static func open(snCode: String, budgetMs: Int = 6_000) async -> OpenOutcome {
        guard !snCode.isEmpty else { return .failed("设备信息不完整") }
        let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000.0)

        // ① 设备上已有订单 → 直接恢复，不再下发
        if let using = try? await queryUsing(snCode: snCode) {
            if using.errorCode == 307 || (using.success && using.data?.orderNo != nil) {
                // ⚠️ 有订单 ≠ 是你的订单，先看 isOwner
                if using.data?.isOwner == false {
                    return .inUseByOthers
                }
                let orderNo = using.data?.orderNo ?? ""
                let pre = using.data?.preDeductMoney.flatMap(Double.init)
                AppLog.shared.i("设备 \(snCode) 已有进行中订单 \(orderNo)，恢复")
                return .resumed(orderNo: orderNo, preDeduct: pre)
            }
        }

        // ② 下发开阀
        let rateResp: APIResponse<DownRateData>
        do {
            let data = try await ApiClient.post(
                "/order/tcpDevice/downRate/rateOrder",
                form: ["xfModel": "0", "snCode": snCode],
                tag: "downRate"
            )
            rateResp = try ApiClient.decode(DownRateData.self, from: data, path: "downRate")
        } catch {
            return .failed("开阀请求失败：\(error.localizedDescription)")
        }

        guard rateResp.success else {
            // ⚠️ errorCode 必须往上传：上层要靠它判断「是不是 306，该不该问用户改用蓝牙」
            if rateResp.errorCode == 306 {
                return .deviceOffline
            }
            return .failed(rateResp.displayMessage ?? "开始失败")
        }

        // ③ 轮询确认（9 次 × 700ms）
        var opened = false
        var autoDisCon = rateResp.data?.autoDisConTime ?? 0
        var confirmedOrderNo = rateResp.data?.orderNo ?? ""
        var consumeDate = rateResp.data?.consumeDate ?? ""

        for i in 0 ..< 9 {
            if i > 0 && Date() >= deadline {
                // 超时未确认：设备可能已经开了（只是还没回执）
                AppLog.shared.w("开阀确认超时（预算 \(budgetMs)ms 用完）")
                break
            }
            try? await Task.sleep(nanoseconds: 700_000_000)

            guard let r = try? await downRateResult(snCode: snCode) else { continue }
            if r.success, let d = r.data, d.looksOpened {
                opened = true
                if let no = d.orderNo, !no.isEmpty { confirmedOrderNo = no }
                if let t = d.autoDisConTime, t > 0 { autoDisCon = t }
                break
            }
        }

        guard opened else {
            return .failed("没能确认设备已开启。如果水已经出了，请先在账单里确认，不要重复点。")
        }

        AppLog.shared.i("云端开阀成功 orderNo=\(confirmedOrderNo) autoDisCon=\(autoDisCon)s")
        return .opened(
            orderNo: confirmedOrderNo,
            consumeDate: consumeDate,
            autoDisCon: autoDisCon,
            preDeduct: rateResp.data?.preDeductYuan
        )
    }

    // MARK: - 关阀

    enum CloseOutcome {
        case closed
        case failed(String)
        /// 请求有没有发出去都不确定 —— 不能当成功，也不能当失败
        case unconfirmed(String)
    }

    static func close(snCode: String, orderNo: String) async -> CloseOutcome {
        guard !snCode.isEmpty else { return .failed("设备信息不完整") }

        // orderNo 必须**在关阀之前**敲定：关阀成功后订单就没了，queryUsing 再也问不出来
        var no = orderNo
        if no.isEmpty {
            no = (try? await queryUsing(snCode: snCode))?.data?.orderNo ?? ""
        }

        let resp: APIResponse<EmptyData>
        do {
            let data = try await ApiClient.post(
                "/order/tcpDevice/closeOrder",
                form: ["snCode": snCode, "orderNo": no],
                tag: "closeOrder"
            )
            resp = try ApiClient.decode(EmptyData.self, from: data, path: "closeOrder")
        } catch {
            // 请求本身失败 → 没有任何证据。再问一次服务端还开着没有
            let running = await orderRunning(snCode: snCode)
            if running == true {
                return .unconfirmed("关阀请求没发出去，设备可能还在用水")
            }
            return .unconfirmed("关阀请求没发出去：\(error.localizedDescription)")
        }

        if !resp.success {
            // 服务端已受理 / 已在关闭中，也算成功
            if resp.errorCode == 307 || (resp.displayMessage?.contains("已在") == true) {
                AppLog.shared.i("关阀已受理（\(resp.errorCode ?? -1)）")
                return .closed
            }
            return .failed(resp.displayMessage ?? "关闭失败，请重试")
        }

        // ⚠️ 这里**不再轮询等待**：closeOrder 已被受理，订单一定会关掉。
        // Android 注释里专门纠正过这一点——再等 5 轮只会让用户白等最多 5 秒，
        // 而 iOS 的界面退出就在 close 返回之后，等待会直接变成可感知的卡顿。
        let running = await orderRunning(snCode: snCode)
        if running != false {
            AppLog.shared.w("关阀已受理，但服务端仍显示订单（running=\(String(describing: running))）")
        }
        return .closed
    }

    // MARK: - 结算

    /// 查本次消费金额。
    ///
    /// 三条路按顺序试，和 Android 的 `SettlementEngine` 同思路但收窄了轮询次数：
    /// 1. `consumeOrder/result/query` 快速探测（3 轮 × 1.2s）
    /// 2. 拿到过明确的 0 就再确认 2 轮（服务端结算慢时，0 和「还没算完」长得一样）
    /// 3. 回退到当月账单列表，按 orderNo 匹配
    ///
    /// 返回 nil = **还不知道**（不是没花钱）
    static func settle(orderNo: String, snCode: String) async -> Double? {
        var sawDefiniteZero = false

        if !orderNo.isEmpty {
            for attempt in 0 ..< 3 {
                if let v = await consumeResult(orderNo: orderNo, snCode: snCode) {
                    if v > 0 {
                        AppLog.shared.i("结算命中（第 \(attempt + 1) 轮）：¥\(MoneyFormat.format(v))")
                        return v
                    }
                    sawDefiniteZero = true
                    break
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }

            if sawDefiniteZero {
                for attempt in 0 ..< 2 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if let v = await consumeResult(orderNo: orderNo, snCode: snCode), v > 0 {
                        AppLog.shared.i("结算命中（零确认第 \(attempt + 1) 轮）：¥\(MoneyFormat.format(v))")
                        return v
                    }
                }
            }
        }

        // 回退：账单列表里按 orderNo 匹配
        if let bill = await BillService.findBill(orderNo: orderNo, snCode: snCode) {
            if let y = bill.yuan {
                AppLog.shared.i("结算回退账单列表命中：¥\(MoneyFormat.format(y))")
                return y
            }
        }

        // 走到这里：直答接口说 0 或不知道，账单列表也没匹配上。
        // 如果见过明确的 0，那就是真零消费；否则是「还不知道」。
        return sawDefiniteZero ? 0.0 : nil
    }

    // MARK: - 单接口封装

    static func queryUsing(snCode: String) async throws -> APIResponse<UsingOrderData> {
        let data = try await ApiClient.post(
            "/order/tcpDevice/query/rateOrder/using",
            form: ["xfModel": "0", "snCode": snCode],
            tag: "queryUsing"
        )
        return try ApiClient.decode(UsingOrderData.self, from: data, path: "queryUsing")
    }

    static func downRateResult(snCode: String) async throws -> APIResponse<DownRateResultData> {
        let data = try await ApiClient.post(
            "/order/tcpDevice/query/downRateResult",
            form: ["snCode": snCode],
            tag: "downRateResult"
        )
        return try ApiClient.decode(DownRateResultData.self, from: data, path: "downRateResult")
    }

    static func consumeResult(orderNo: String, snCode: String) async -> Double? {
        guard !orderNo.isEmpty else { return nil }
        do {
            let data = try await ApiClient.post(
                "/order/consumeOrder/result/query",
                form: ["snCode": snCode, "orderNo": orderNo],
                tag: "consumeResult"
            )
            let resp = try ApiClient.decode(ConsumeResultData.self, from: data, path: "consumeResult")
            guard resp.success, let v = resp.data?.yuan, v.isFinite, v >= 0 else { return nil }
            return v
        } catch {
            return nil
        }
    }

    static func orderRunning(snCode: String) async -> Bool? {
        guard let resp = try? await queryUsing(snCode: snCode) else { return nil }
        if resp.errorCode == 307 { return true }
        if resp.success { return resp.data?.orderNo != nil }
        return nil
    }
}

/// 一些接口只关心 `success`，`data` 是 null
struct EmptyData: Decodable {}
