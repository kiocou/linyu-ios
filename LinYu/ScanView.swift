import SwiftUI
import UIKit

/// BLE 扫描验证页。
///
/// 只做一件���：把附近所有 BLE 设备的**原始广播信息**列出来，
/// 用于判断 iOS 能否在 12 台同型号设备中区分出目标那一台。
///
/// 重点关注：
/// 1. `manufacturerData` / `serviceData` 里有没有 SN 或设备编号
/// 2. 同型号设备的广播数据是否互不相同
/// 3. 设备名是否区分了房间
struct ScanView: View {
    @StateObject private var scanner = BLEScanner()
    /// 展开查看详细广播数据的设备
    @State private var expanded: Set<UUID> = []
    @State private var copiedHint: String?

    var body: some View {
        List {
            Section {
                statusRow
            }

            if scanner.devices.isEmpty {
                Section {
                    emptyHint
                }
            } else {
                Section {
                    ForEach(scanner.devices) { device in
                        deviceRow(device)
                    }
                } header: {
                    HStack {
                        Text("附近设备（\(scanner.devices.count)）")
                        Spacer()
                        Button {
                            copyAll()
                        } label: {
                            Label("复制全部", systemImage: "doc.on.doc")
                                .labelStyle(.titleOnly)
                                .font(.caption)
                        }
                    }
                }
            }

            Section {
                analysisHint
            }
        }
        .navigationTitle("BLE 扫描")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { scanner.stop() }
    }

    // MARK: - 子视图

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(scanner.isScanning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(scanner.stateText)
                    .font(.subheadline)
                Spacer()
                Text("回调 \(scanner.callbackCount)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    scanner.isScanning ? scanner.stop() : scanner.start()
                } label: {
                    Label(
                        scanner.isScanning ? "停止" : "开始扫描",
                        systemImage: scanner.isScanning ? "stop.circle.fill" : "antenna.radiowaves.left.and.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有扫到设备")
                .font(.subheadline.weight(.medium))
            Text("点「开始扫描」，然后把手机拿到热水器旁边。热水表广播间隔短，通常几秒内就能出现。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func deviceRow(_ device: DiscoveredPeripheral) -> some View {
        let isOpen = expanded.contains(device.id)
        return VStack(alignment: .leading, spacing: 8) {
            // 主行：名称 + 信号强度
            HStack(alignment: .firstTextBaseline) {
                Text(device.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(device.rssi) dBm")
                    .font(.caption.monospaced())
                    .foregroundStyle(rssiColor(device.rssi))
            }

            // identifier（就是 iOS 能拿到的"地址"）
            HStack(spacing: 6) {
                Text("id")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(String(device.id.uuidString.prefix(8)) + "…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if device.isConnectable {
                    Text("可连接")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    keyValue("完整 identifier", device.id.uuidString)

                    if !device.serviceUUIDs.isEmpty {
                        keyValue("Service UUID", device.serviceUUIDs.joined(separator: "\n"))
                    }
                    if let m = device.manufacturerData {
                        keyValue("manufacturerData", m)
                    }
                    if let s = device.serviceData {
                        keyValue("serviceData", s)
                    }
                    if device.manufacturerData == nil && device.serviceData == nil {
                        Text("这台设备没有广播 manufacturerData / serviceData")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)
            }

            HStack {
                Button(isOpen ? "收起" : "查看广播数据") {
                    if isOpen { expanded.remove(device.id) } else { expanded.insert(device.id) }
                }
                .font(.caption)
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    UIPasteboard.general.string = describe(device)
                    copiedHint = device.name
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption)
                        .labelStyle(.titleOnly)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var analysisHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("看完这些数据后，请回答三个问题")
                .font(.footnote.weight(.semibold))
            Text("""
            1. 同型号的多台设备，manufacturerData 或 serviceData 是否互不相同？
            2. 这些字段里能不能找到和设备 SN（如 001583E56112）对应的部分？
            3. 设备名里有没有房间信息（如 105 房）？
            """)
            .font(.caption)
            .foregroundStyle(.secondary)

            if let copiedHint {
                Divider()
                Text("已复制 \(copiedHint) 的原始数据")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 工具

    private func keyValue(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case ..<(-80): return .red
        case ..<(-65): return .orange
        default:       return .green
        }
    }

    private func describe(_ d: DiscoveredPeripheral) -> String {
        var lines = [
            "name: \(d.name)",
            "identifier: \(d.id.uuidString)",
            "rssi: \(d.rssi)",
            "connectable: \(d.isConnectable)",
            "serviceUUIDs: \(d.serviceUUIDs.joined(separator: ", "))"
        ]
        if let m = d.manufacturerData { lines.append("manufacturerData: \(m)") }
        if let s = d.serviceData { lines.append("serviceData: \(s.replacingOccurrences(of: "\n", with: " | "))") }
        return lines.joined(separator: "\n")
    }

    private func copyAll() {
        let text = scanner.devices.map(describe).joined(separator: "\n\n---\n\n")
        UIPasteboard.general.string = text
        copiedHint = "全部 \(scanner.devices.count) 台"
    }
}

#Preview {
    NavigationStack {
        ScanView()
    }
}
