import SwiftUI

@main
struct LinYuApp: App {
    init() {
        AppLog.shared.i("App 启动")
        AppNotifications.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if #available(iOS 17.0, *), CommandLine.arguments.contains("--widget-preview") {
                WidgetPreviewScreen()
            } else {
                RootView().onOpenURL { WidgetBridge.shared.receive($0) }
            }
            #else
            RootView().onOpenURL { WidgetBridge.shared.receive($0) }
            #endif
        }
    }
}
