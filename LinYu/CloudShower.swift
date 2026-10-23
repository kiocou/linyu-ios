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
        /// 服务端**明确拒绝**（success=false 且不是 306）。
        /// 只有这一类才可能和「欠费」有关，上层据此决定弹窗里要不要给「立即补扣」。
        case rejected(String)
        /// 本地/网络层面的失败（参数不全、请求发不出去、确认超时……）
        case failed(String)
    }

    /// 开阀。`budgetMs` 是轮询确认的总预算（Android 也是 6 秒）。
    static func open(snCode: String, budgetMs: Int = 6_000, allowNewOrder: Bool = true, expectedOrderNo: String? = nil) async -> OpenOutcome {
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
                if let expectedOrderNo, !expectedOrderNo.isEmpty, expectedOrderNo != orderNo {
                    return .failed("设备订单已变化，请刷新设备状态后操作")
                }
                let pre = using.data?.preDeductMoney?.value
                AppLog.shared.i("设备 \(snCode) 已有进行中订单 \(orderNo)，恢复")
                return .resumed(orderNo: orderNo, preDeduct: pre)
            }
        }

        // 恢复/通知不是开新阀的授权：查询失败或已无订单时不能申请费率。
        guard allowNewOrder else { return .failed("未能确认原订单仍在使用，请刷新设备状态") }

        // ② 下发开阀
        let rateResp: APIResponse<DownRateData>
        do {
            let data = try await ApiClient.post(
                "/order/tcpDevice/downRate/rateOrder",
                form: ["xfModel": "0", "snCode": snCode],
                tag: "downRate"
            )
            // ⚠️ 必须 decodeShell：业务失败（尤其是 306「设备不在线」）要能看得到 errorCode，
            // 而 `decode` 会把它变成异常，下面的 306 分支就永远走不到——
            // 结果就是「蓝牙表只能蓝牙开」这件事在 iOS 上无从触发。
            rateResp = try ApiClient.decodeShell(DownRateData.self, from: data, path: "downRate")
        } catch {
            return .failed("开阀请求失败：\(error.localizedDescription)")
        }

        guard rateResp.success else {
            // ⚠️ errorCode 必须往上传：上层要靠它判断「是不是 306，该不该问用户改用蓝牙」
            if rateResp.errorCode == 306 {
                return .deviceOffline
            }
            return .rejected(rateResp.displayMessage ?? "开始失败")
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
            resp = try ApiClient.decodeShell(EmptyData.self, from: data, path: "closeOrder")
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

    // 结算逻辑已抽到 `SettlementEngine`（对照 Android 的 `data/SettlementEngine.kt`）：
    // 三态探询 + 零确认 + 账单列表回退 + 待对账登记全在那里。
    // 这里不再重复实现一份，否则两边判据一改就会不一致。

    // MARK: - 单接口封装

    static func queryUsing(snCode: String) async throws -> APIResponse<UsingOrderData> {
        let data = try await ApiClient.post(
            "/order/tcpDevice/query/rateOrder/using",
            form: ["xfModel": "0", "snCode": snCode],
            tag: "queryUsing"
        )
        // ⚠️ decodeShell：307（已有订单）是**正常语义**，走 decode 就被吞成 nil，
        // 于是「恢复已有订单」永远不生效，只能重复下发开阀。
        return try ApiClient.decodeShell(UsingOrderData.self, from: data, path: "queryUsing")
    }

    static func downRateResult(snCode: String) async throws -> APIResponse<DownRateResultData> {
        let data = try await ApiClient.post(
            "/order/tcpDevice/query/downRateResult",
            form: ["snCode": snCode],
            tag: "downRateResult"
        )
        return try ApiClient.decodeShell(DownRateResultData.self, from: data, path: "downRateResult")
    }

    /// 拿这次用水**真正的** orderNo：本地存了就用本地的，没存就问服务端并回填。
    ///
    /// ⚠️ **必须在关阀之前调**：关阀成功后订单就没了，`queryUsing` 再也问不出来。
    /// 所有需要 orderNo 的接口（结算、关阀）都靠它，拿不到就只能退化成按时间窗猜账单。
    static func resolveOrderNo(snCode: String) async -> String {
        let cached = ActiveOrderStore.find(snCode)?.orderNo ?? ""
        if !cached.isEmpty { return cached }
        let fresh = await queryOrderNo(snCode: snCode)
        if !fresh.isEmpty {
            ActiveOrderStore.updateOrderNo(snCode: snCode, orderNo: fresh)
            AppLog.shared.i("orderNo 本地缺失，已从服务端回填：\(fresh)")
        }
        return fresh
    }

    /// 查询设备上进行中订单的订单号，没有则返回空串
    static func queryOrderNo(snCode: String) async -> String {
        guard let p = try? await queryUsing(snCode: snCode) else { return "" }
        if p.errorCode == 307 || (p.success && p.data?.orderNo != nil) {
            return p.data?.orderNo ?? ""
        }
        return ""
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
