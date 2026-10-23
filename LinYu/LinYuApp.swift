import SwiftUI

@main
struct LinYuApp: App {
    init() {
        AppLog.shared.i("App 启动")
        AppNotifications.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
