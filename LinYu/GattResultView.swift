import SwiftUI
import UIKit

/// 连接测试结果：展示 GATT 服务/特征的发现过程与结论。
///
/// 这一步只验证「iOS 连上后能不能看到 FF00/FF01/FF02」，
/// **不发任何业务命令、不写特征、不开阀**。
///
/// 为什么先验证这个：Android 端依赖 FF00 服务通信，但 iOS 的 CoreBluetooth
/// 在服务发现上和 Android 有差异（比如需要先请求 MTU、某些设备会隐藏服务）。
/// 确认能看到这三个 UUID，后面的协议迁移才有意义。
struct GattResultView: View {
    @ObservedObject var scanner: BLEScanner
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text(scanner.gattSummary.isEmpty ? "等待结果…" : scanner.gattSummary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(summaryColor)
            } header: {
                Text("结论")
            }

            Section {
                if scanner.gattLog.isEmpty {
                    Text("等待发现服务…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(scanner.gattLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("GATT 结构")
            } footer: {
                Text("SERVICE = 服务，CHAR = 特征，方括号内是属性（read/write/notify…）")
                    .font(.caption2)
            }

            Section {
                Button {
                    Task { await scanner.queryState() }
                } label: {
                    HStack {
                        Label("查询设备状态（0x23）", systemImage: "waveform.path.ecg")
                        Spacer()
                        if scanner.isQuerying {
                            ProgressView()
                        }
                    }
                }
                .disabled(scanner.isQuerying || scanner.connectedId == nil)

                if !scanner.queryResult.isEmpty {
                    Text(scanner.queryResult)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("读取设备状态（只读）")
            } footer: {
                Text("只发送状态查询，不下发费率、不开阀、不动钱。成功后能看到 state / randomNumber / devType —— 这些是开阀的前置条件。")
                    .font(.caption2)
            }

            Section {
                Button {
                    let text = scanner.gattSummary + "\n\n" + scanner.gattLog.joined(separator: "\n")
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制全部结果", systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    scanner.disconnect()
                } label: {
                    Label("断开连接", systemImage: "xmark.circle")
                }
            }
        }
        .navigationTitle("连接测试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
    }

    private var summaryColor: Color {
        let s = scanner.gattSummary
        if s.hasPrefix("✅") { return .green }
        if s.hasPrefix("⚠️") { return .orange }
        if s.hasPrefix("❌") { return .red }
        return .secondary
    }
}
