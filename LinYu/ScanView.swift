import SwiftUI
import UIKit

/// BLE 扫描验证页。
///
/// 把附近 BLE 设备的**原始广播信息**列出来，用于判断 iOS 能否在
/// 12 台同型号设备中区分出目标那一台。
///
/// ## 2026-10-22 实测结论
///
/// 该型号水表的 `manufacturerData` 形如 `00 00 C4 7F 0E DD 2E 9C`：
/// 前 2 字节是 Company ID，后 6 字节就是 MAC，去掉冒号即 `snCode`。
/// 所以页面会直接把解析出的 snCode 显示出来——不用再靠名字猜。
///
/// ## 关于筛选
///
/// 直接列全部会把附近所有蓝牙设备都倒出来（耳机、手环、共享单车…），
/// 所以默认只显示「看起来像水控设备」的。但**默认筛选不能是唯一选项**，
/// 顶部永远保留「全部」开关和搜索框。
struct ScanView: View {
    @StateObject private var scanner = BLEScanner()
    /// 展开查看详细广播数据的设备
    @State private var expanded: Set<UUID> = []
    @State private var copiedHint: String?
    /// false = 只看可能的设备；true = 显示全部
    @State private var showAll = false
    /// 名称搜索
    @State private var searchText = ""

    /// 日志文件（生成后弹分享面板）
    @State private var logFileURL: URL?
    @State private var showShareSheet = false
    /// 连接测试结果面板
    @State private var showGatt = false

    /// 按当前筛选条件算出的可见列表
    private var visibleDevices: [DiscoveredPeripheral] {
        var list = scanner.devices
        if !showAll {
            list = list.filter(\.looksLikeWaterMeter)
        }
        let kw = searchText.trimmingCharacters(in: .whitespaces)
        if !kw.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(kw)
                    || $0.id.uuidString.localizedCaseInsensitiveContains(kw)
                    || ($0.manufacturerHex ?? "").localizedCaseInsensitiveContains(kw)
                    || ($0.parsedSnCode ?? "").localizedCaseInsensitiveContains(kw)
            }
        }
        return list
    }

    private var likelyCount: Int {
        scanner.devices.filter(\.looksLikeWaterMeter).count
    }

    private var snCodeCount: Int {
        scanner.devices.filter { $0.parsedSnCode != nil }.count
    }

    var body: some View {
        List {
            Section {
                statusRow
            }

            Section {
                filterRow
            }

            if visibleDevices.isEmpty {
                Section {
                    emptyHint
                }
            } else {
                Section {
                    ForEach(visibleDevices) { device in
                        deviceRow(device)
                    }
                } header: {
                    HStack {
                        Text("设备（\(visibleDevices.count)）")
                        Spacer()
                        Button {
                            copyAll()
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .labelStyle(.titleOnly)
                                .font(.caption)
                        }
                    }
                }
            }

            Section {
                exportRow
            }

            Section {
                analysisHint
            }
        }
        .navigationTitle("BLE 扫描")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "按名称 / id / snCode 搜索")
        .onDisappear { scanner.stop() }
        .sheet(isPresented: $showShareSheet) {
            if let url = logFileURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showGatt) {
            NavigationStack {
                GattResultView(scanner: scanner)
            }
        }
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
        .padding(.vertical, 4)
    }

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("筛选", selection: $showAll) {
                Text("可能的水表 \(likelyCount)").tag(false)
                Text("全部 \(scanner.devices.count)").tag(true)
            }
            .pickerStyle(.segmented)

            if scanner.devices.count > 0 && likelyCount == 0 {
                Text("没有匹配到水表特征。可以切到「全部」看看——目标设备可能没有名字，也没带广播数据。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if snCodeCount > 0 {
                Text("已从 \(snCodeCount) 台设备的 broadcast 里解析出 snCode")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(searchText.isEmpty ? "当前筛选下没有设备" : "没有匹配「\(searchText)」的设备")
                .font(.subheadline.weight(.medium))
            Text("""
            先确认：蓝牙已打开、App 有蓝牙权限。
            然后把手机靠近热水表——热水表广播间隔很短，几秒内就会出现。

            如果一直扫不到，切到「全部」看看是不是被筛掉了。
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var exportRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                saveLog()
            } label: {
                Label("保存日志（\(visibleDevices.count) 台）", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(visibleDevices.isEmpty)

            Text("生成一个 txt 文件，可以存到「文件」、AirDrop 或发到电脑。里面包含每台设备的 snCode、广播原始 hex、RSSI 等。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let copiedHint {
                Text("已复制：\(copiedHint)")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private func deviceRow(_ device: DiscoveredPeripheral) -> some View {
        let isOpen = expanded.contains(device.id)
        return VStack(alignment: .leading, spacing: 8) {
            // 主行：名称 + 信号强度
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                confidenceIcon(device)
                Text(device.isUnnamed ? "(未命名)" : device.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(device.isUnnamed ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Text("\(device.rssi) dBm")
                    .font(.caption.monospaced())
                    .foregroundStyle(rssiColor(device.rssi))
            }

            // snCode：这是最关键的信息
            if let sn = device.parsedSnCode {
                HStack(spacing: 6) {
                    Text("SN")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(sn)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.blue)
                        .textSelection(.enabled)
                }
            }

            // identifier（iOS 系统分配的 UUID，不是 MAC）
            HStack(spacing: 6) {
                Text("id")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(String(device.id.uuidString.prefix(8)) + "…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if device.isConnectable {
                    tag("可连接", .green)
                }
                if device.hasKlcxkjService {
                    tag("FEE7", .blue)
                }
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    keyValue("完整 identifier", device.id.uuidString)

                    if !device.serviceUUIDs.isEmpty {
                        keyValue("Service UUID", device.serviceUUIDs.joined(separator: "\n"))
                    }
                    if let m = device.manufacturerHex {
                        keyValue("manufacturerData", m)
                    }
                    if let mac = device.parsedMac {
                        keyValue("解析出的 MAC", mac)
                    }
                    if let s = device.serviceDataHex {
                        keyValue("serviceData", s)
                    }
                    if device.manufacturerData == nil && device.serviceData.isEmpty {
                        Text("这台设备没有广播 manufacturerData / serviceData")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)
            }

            HStack(spacing: 14) {
                Button(isOpen ? "收起" : "查看广播数据") {
                    if isOpen { expanded.remove(device.id) } else { expanded.insert(device.id) }
                }
                .font(.caption)
                .buttonStyle(.borderless)

                Button {
                    UIPasteboard.general.string = describe(device)
                    copiedHint = device.name
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption)
                        .labelStyle(.titleOnly)
                }
                .buttonStyle(.borderless)

                Spacer()

                // 只对疑似水表提供连接测试——连一台耳机没有意义
                if device.confidence != .unknown {
                    Button {
                        scanner.connect(device.id)
                        showGatt = true
                    } label: {
                        Label("连接测试", systemImage: "link")
                            .font(.caption)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var analysisHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("保存日志后发我，重点看这些")
                .font(.footnote.weight(.semibold))
            Text("""
            • snCode 是否和 Android 端看到的一致（如 C47F0EDCBCC7）
            • 同型号多台设备的 snCode 是否互不相同
            • 有没有哪台命中 FEE7 但解析不出 snCode
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 工具

    private func confidenceIcon(_ device: DiscoveredPeripheral) -> some View {
        Group {
            switch device.confidence {
            case .certain:
                Image(systemName: "drop.fill").foregroundStyle(.blue)
            case .likely:
                Image(systemName: "drop").foregroundStyle(.blue.opacity(0.6))
            case .unknown:
                Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

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
        if let m = d.manufacturerHex { lines.append("manufacturerData: \(m)") }
        if let sn = d.parsedSnCode { lines.append("parsedSnCode: \(sn)") }
        if let s = d.serviceDataHex {
            lines.append("serviceData: \(s.replacingOccurrences(of: "\n", with: " | "))")
        }
        return lines.joined(separator: "\n")
    }

    private func copyAll() {
        let text = visibleDevices.map(describe).joined(separator: "\n\n---\n\n")
        UIPasteboard.general.string = text
        copiedHint = "当前列表 \(visibleDevices.count) 台"
    }

    private func saveLog() {
        guard let url = ScanLogStore.write(devices: visibleDevices) else {
            copiedHint = "日志写入失败"
            return
        }
        logFileURL = url
        showShareSheet = true
    }
}

/// 系统分享面板（UIActivityViewController）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        ScanView()
    }
}
