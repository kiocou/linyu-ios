import SwiftUI

/// 三 Tab 容器 —— 对照 Android 的 `MainActivity`。
///
/// - 用水时**整屏**切成 `ShowerScreenView`，不显示底部导航（和 Android 一致）
/// - Tab 切换是弹性左右滑移（Android 用 `AnimatedContent` + spring 420/0.78）
/// - Toast 挂在这一层，因为开阀/结算的提示可能发生在任意 Tab
struct MainTabView: View {
    @Environment(\.appColors) private var colors
    @Environment(\.isDarkMode) private var isDark

    @State private var tab = 0
    /// 会话状态在容器里持有：首页、用水页、我的页共用同一条 BLE 连接
    @StateObject private var flow = ShowerFlow()
    /// 账单/余额缓存（对照 Android 的 MainViewModel：跨页面存活，切换不重载）
    @StateObject private var store = AppDataStore()
    /// 扫描器放在容器里：首页展示列表、「我的 → 绑定寝室」读附近设备，共用同一份结果
    @StateObject private var scanner = BLEScanner()
    /// 进「我的 → 设置」时隐藏底部导航（Android 也是这么做的）
    @State private var settingsVisible = false
    /// 从首页改完设置（寝室筛选等）要让首页刷新，用一个计数器触发
    @State private var refreshToken = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            colors.background.ignoresSafeArea()

            if let order = flow.activeOrder {
                ShowerScreenView(
                    emoji: order.device.typeEmoji,
                    statusText: order.device.statusText,
                    location: order.device.displayName,
                    remaining: preDeductText(order),
                    elapsedSec: order.elapsedSeconds,
                    autoDisConSec: order.autoDisConRemain,
                    isStopping: flow.isStopping,
                    onStop: { Task { await flow.close() } },
                    onMinimize: {}
                )
                .transition(.opacity)
            } else {
                Group {
                    switch tab {
                    case 0:
                        MainScreenView(scanner: scanner, flow: flow, store: store)
                            .id(refreshToken)
                    case 1:
                        WalletScreenView(flow: flow, store: store)
                    default:
                        UserScreenView(flow: flow, scanner: scanner, settingsVisible: $settingsVisible)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // ⚠️ 只做透明度交叉淡入，**不做位移动画**。
                // 之前用 .move(edge:) 时，切页瞬间新旧两页同时在屏幕上横向滑动，
                // 滚动中的长列表会拖出残影，看着像界面被"平移"了一下。
                // Android 那边的页面是各自独立的 ScrollView、切换由 AnimatedContent
                // 整体替换，不会有两页并存的观感；iOS 用淡入淡出最接近。
                .transition(.opacity)

                if !settingsVisible {
                    PillNavBar(currentTab: $tab, colors: colors)
                        .padding(.bottom, 22)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }
            }

            // Toast：开阀/结算/扫描的提示都走这一条通道。
            //
            // ⚠️ 位置在**顶部**（对照 Android `LinYuToast` 的 Alignment.TopCenter
            // + padding(top = 60.dp)），从上方滑入。放底部会和悬浮导航栏打架，
            // 也和安卓端不一致。
            if let toast = flow.toast, !toast.isEmpty {
                VStack {
                    LinYuToast(message: toast, isDark: isDark)
                        .padding(.top, 60)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                        .allowsHitTesting(false)
                    Spacer()
                }
                .animation(.easeInOut(duration: 0.18), value: toast)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: tab)
        .animation(.easeInOut(duration: 0.22), value: flow.activeOrder != nil)
        .onChange(of: flow.toast) { value in
            guard let msg = value, !msg.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                // 只在还是同一条消息时才清，避免把后来的新消息误关
                if flow.toast == msg { flow.toast = nil }
            }
        }
    }

    private func preDeductText(_ order: ActiveOrder) -> String {
        guard let p = order.preDeductMoney, p > 0 else { return "0.00" }
        return String(format: "%.2f", p)
    }
}
