import SwiftUI
import UIKit

/// 空壳验证页 + 入口。
///
/// 保留构建信息（证明包是完整可运行的），并加入 BLE 扫描入口——
/// 这是 iOS 版最关键的风险验证：**能不能在 12 台同型号设备中认出目标那台**。
struct ContentView: View {
    var body: some View {
        NavigationStack {
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

                Spacer()
                    .frame(height: 24)

                NavigationLink {
                    ScanView()
                } label: {
                    Label("BLE 扫描验证", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text("扫描附近设备，查看广播数据里能否识别出具体是哪一台")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .navigationBarHidden(true)
        }
    }
}

enum BuildInfo {
    static var summary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return """
        版本 \(version) (\(build))
        \(UIDevice.osName) \(UIDevice.osVersion)
        \(UIDevice.friendlyModel)
        """
    }
}

#Preview {
    ContentView()
}
