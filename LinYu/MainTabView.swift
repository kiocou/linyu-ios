import SwiftUI

/// 三 Tab 容器 —— 对照 Android 的底部导航（首页 / 账单 / 我的）。
///
/// 用水时**整屏**切成 `ShowerScreenView`（不显示导航栏），
/// 和 Android 一致：进用水页就没有底栏了。
struct MainTabView: View {
    @Environment(\.appColors) private var colors
    @Environment(\.isDarkMode) private var isDark

    @State private var tab = 0
    /// 会话状态在容器里持有，首页和用水页共用同一条 BLE 连接
    @StateObject private var flow = ShowerFlow()

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
                    autoDisConSec: 0,
                    isStopping: isClosing,
                    onStop: { Task { await flow.close() } },
                    onMinimize: {}
                )
                .transition(.opacity)
            } else {
                Group {
                    switch tab {
                    case 0:
                        MainScreenView(flow: flow)
                    case 1:
                        WalletScreenView()
                    default:
                        UserScreenView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PillNavBar(currentTab: $tab, colors: colors)
                    .padding(.bottom, 22)
                    .padding(.horizontal, 24)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: flow.activeOrder != nil)
    }

    private var isClosing: Bool {
        switch flow.stage {
        case .closing, .collecting, .uploading, .writingBack: return true
        default: return false
        }
    }

    private func preDeductText(_ order: ActiveOrder) -> String {
        guard let p = order.preDeductMoney, p > 0 else { return "0.00" }
        return String(format: "%.2f", p)
    }
}
