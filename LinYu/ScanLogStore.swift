import Foundation
import UIKit

/// 把扫描结果落成文本文件，供系统分享面板导出。
///
/// 为什么用文件而不是只复制到剪贴板：
/// - 剪贴板在设备间传很不方便（尤其要发到 Windows）
/// - 文件可以通过「存储到文件」进 iCloud Drive，或者直接 AirDrop / 微信发出来
///
/// 格式刻意做成「人能读、程序也能解析」的键值行，和 Android 端日志的风格一致。
enum ScanLogStore {

    /// 生成日志文件，返回文件 URL；失败返回 nil
    static func write(
        devices: [DiscoveredPeripheral],
        note: String? = nil
    ) -> URL? {
        let text = makeText(devices: devices, note: note)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileName = "linyu-ble-scan-\(formatter.string(from: Date())).txt"

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(fileName)

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// 生成纯文本内容（也用于复制到剪贴板）
    static func makeText(
        devices: [DiscoveredPeripheral],
        note: String? = nil
    ) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let model = UIDevice.modelIdentifier
        let system = "\(UIDevice.osName) \(UIDevice.osVersion)"

        var lines: [String] = []
        lines.append("# LinYu iOS BLE 扫描日志")
        lines.append("生成时间: \(df.string(from: Date()))")
        lines.append("App 版本: \(appVersion) (\(appBuild))")
        lines.append("设备: \(model) / \(system)")
        lines.append("设备总数: \(devices.count)")
        lines.append("其中疑似水表: \(devices.filter(\.looksLikeWaterMeter).count)")
        if let note, !note.isEmpty {
            lines.append("备注: \(note)")
        }
        lines.append("")

        for (index, d) in devices.enumerated() {
            lines.append("=== [\(index + 1)] \(d.isUnnamed ? "(未命名)" : d.name) ===")
            lines.append("name: \(d.name)")
            lines.append("identifier: \(d.id.uuidString)")
            lines.append("rssi: \(d.rssi)")
            lines.append("connectable: \(d.isConnectable)")
            lines.append("serviceUUIDs: \(d.serviceUUIDs.joined(separator: ", "))")
            lines.append("hasKlcxkjService(FEE7): \(d.hasKlcxkjService)")
            if let hex = d.manufacturerHex {
                lines.append("manufacturerData: \(hex)")
            }
            if let sn = d.parsedSnCode {
                lines.append("parsedSnCode: \(sn)")
            }
            if let mac = d.parsedMac {
                lines.append("parsedMac: \(mac)")
            }
            if let sd = d.serviceDataHex {
                lines.append("serviceData: \(sd.replacingOccurrences(of: "\n", with: " | "))")
            }
            lines.append("confidence: \(confidenceLabel(d.confidence))")
            lines.append("")
        }

        if devices.isEmpty {
            lines.append("（本次没有任何扫描结果）")
        }

        return lines.joined(separator: "\n")
    }

    private static func confidenceLabel(_ c: DiscoveredPeripheral.Confidence) -> String {
        switch c {
        case .certain: return "certain（FEE7 + 可解析 snCode）"
        case .likely:  return "likely"
        case .unknown: return "unknown"
        }
    }
}
