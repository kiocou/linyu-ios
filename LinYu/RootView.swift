import SwiftUI

/// 根据登录态切根视图
struct RootView: View {
    @ObservedObject private var session = Session.shared

    var body: some View {
        Group {
            if session.isLoggedIn {
                HomeView()
                    .environmentObject(session)
            } else {
                LoginView()
                    .environmentObject(session)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.isLoggedIn)
    }
}
