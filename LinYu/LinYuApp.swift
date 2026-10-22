import SwiftUI

@main
struct LinYuApp: App {
    init() {
        AppLog.shared.i("App 启动")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
