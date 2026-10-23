import Foundation

/// 主动挤号检测 —— 逐条对照 Android `MainViewModel.startKickWatch`。
///
/// ## 为什么需要它
///
/// 服务端允许同一账号在别处登录，旧会话的 `loginCode` 会被作废。之后任何请求都会
/// 返回「登录失效」，但用户可能**正在使用页**上 —— 他只看到结算失败、账单拉不出来，
/// 不知道发生了什么，会以为是网络问题反复点。
///
/// 这里每 25 秒问一次 `/account/wallet`：
/// - 成功：**顺手把钱包余额刷新了**（这条心跳反正要跑，不加请求量，
///   却让余额在洗完澡后自动跟上，不用等用户下拉刷新）
/// - 失败：只有「401/403」和明确的失效文案才算挤号。网络错误不算 ——
///   断网时把用户踢下线是最糟糕的处理
///
/// ⚠️ 生命周期跟随主界面（`MainTabView`）：退到登录页就该停，别在后台空转。
@MainActor
final class KickWatch: ObservableObject {

    /// Android 的 `kickWatchIntervalMs` 是 25 秒，保持一致
    static let intervalSec: UInt64 = 25

    private var task: Task<Void, Never>?

    /// 服务端用来表示「登录失效」的文案关键词。
    ///
    /// ⚠️ 只能靠文案兜底：服务端这类响应没有独立 errorCode
    /// （Android 那边也是同一份关键词表，别自己发明新的）。
    private static let kickKeywords = [
        "登录", "token", "失效", "过期", "认证", "未登录", "请重新",
    ]

    func start() {
        guard task == nil else { return }
        AppLog.shared.i("挤号检测启动（每 \(Self.intervalSec)s）")
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.intervalSec * 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        // 已经登出了（正常退出或被挤）就不用再问了
        guard Session.shared.isLoggedIn, Session.shared.kickedReason == nil else { return }

        let probe = await BillService.probeWallet()

        if probe.ok {
            // 顺手刷新余额（对照 Android：心跳里带上余额）
            if let v = probe.wallet?.moneyYuan {
                Prefs.walletBalance = String(v)
            }
            return
        }

        if probe.code == 401 || probe.code == 403 {
            Session.shared.kickOut(reason: probe.message ?? "登录已失效，请重新登录")
            return
        }

        // ⚠️ 网络异常/超时 **不算** 挤号。Android 的 checkKickEx 也只认 401/403
        guard let message = probe.message, !message.isEmpty else { return }
        for keyword in Self.kickKeywords where message.contains(keyword) {
            Session.shared.kickOut(reason: message)
            return
        }
    }
}
