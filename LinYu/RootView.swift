import SwiftUI

/// 根视图：注入主题色 + 按登录态切页。
///
/// 主题色用 `Environment` 往下传，任何子视图读 `@Environment(\.appColors)` 即可，
/// 不用每个页面都接一个 `@EnvironmentObject`。
struct RootView: View {
    @ObservedObject private var session = Session.shared
    @AppStorage("linyu.darkMode") private var isDark = false

    private var colors: AppColorSet { isDark ? .dark : .light }

    var body: some View {
        Group {
            if session.isLoggedIn {
                MainTabView()
                    .id(session.projectId + ":" + session.accountId)
                    .environmentObject(session)
            } else {
                LoginView()
                    .environmentObject(session)
            }
        }
        // 被挤下线：用系统弹窗告知原因，关掉才真的回到登录页
        // （对照 Android 的强制下线弹窗。不告知的话用户只会看到「莫名其妙退出了」）
        .alert(
            "登录已失效",
            isPresented: Binding(
                get: { session.kickedReason != nil },
                set: { if !$0 { _ = session.consumeKickReason() } }
            )
        ) {
            Button("重新登录", role: .cancel) { _ = session.consumeKickReason() }
        } message: {
            Text(session.kickedReason ?? "账号已在其他设备登录，请重新登录。")
        }
        .environment(\.appColors, colors)
        .environment(\.isDarkMode, isDark)
        .preferredColorScheme(isDark ? .dark : .light)
        .tint(colors.accent)
    }
}
