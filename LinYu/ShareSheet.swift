import SwiftUI
import UIKit

/// 系统分享面板（`UIActivityViewController`）—— 日志导出用。
///
/// 原先这几个定义混在早期的 BLE 验证页（`ScanView.swift`）里，那个页面已经删掉了，
/// 但 `LogView` 的导出还在用它，所以单独放到这里。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
