import SwiftUI
import UIKit

/// 空壳验证页。
///
/// 目的只有一个：确认「GitHub Actions 构建 → 下载 ipa → Sideloadly 自签 → 装进 iPhone」
/// 这条链路能走通。所以这里刻意不接任何网络和蓝牙，只显示构建信息——
/// 装到手机上能读到版本号和系统信息，就说明包是完整可运行的。
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("🚿")
                .font(.system(size: 64))

            Text("淋浴")
                .font(.largeTitle.bold())

            Text("iOS 空壳验证")
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 8)

            Text(BuildInfo.summary)
                .font(.footnote.monospaced())
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

enum BuildInfo {
    static var summary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        return """
        版本 \(version) (\(build))
        \(device.systemName) \(device.systemVersion)
        \(device.model)
        """
    }
}

#Preview {
    ContentView()
}
