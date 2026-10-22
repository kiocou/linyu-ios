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
                    .environmentObject(session)
            } else {
                LoginView()
                    .environmentObject(session)
            }
        }
        .environment(\.appColors, colors)
        .environment(\.isDarkMode, isDark)
        .preferredColorScheme(isDark ? .dark : .light)
        .tint(colors.accent)
    }
}
