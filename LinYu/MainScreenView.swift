import SwiftUI
import CoreBluetooth

/// 主界面 —— 对照 Android 的 `MainScreen.kt`。
///
/// 结构（自上而下）：
/// ```
/// 淋浴 / Hualala            [扫码] [刷新]
/// 使用中的设备 / 上次使用设备
/// 附近设备                余额 ¥—
/// 🏠 已筛选：320房  取消筛选
/// ● 扫描中...        ●强 ●中 ●弱
/// [设备卡片…]
/// ```
/// 底部悬浮胶囊导航；用水时整屏切成 `ShowerScreenView`。
struct MainScreenView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.appColors) private var colors
    @Environment(\.isDarkMode) private var isDark

    @StateObject private var scanner = BLEScanner()
    /// 由 MainTabView 注入，用水页也在那一层切换
    @ObservedObject var flow: ShowerFlow

    /// snCode → 台账
    @State private var resolved: [String: DeviceInfo] = [:]
    @State private var resolving: Set<String> = []
    @State private var toast: String?
    @State private var showLog = false
    @State private var selectedDevice: DeviceInfo?
    @State private var showDetail = false

    // 上次使用的设备（对照 PrefsHelper 的 lastDevice*）
    @AppStorage("lastDeviceName") private var lastDeviceName = ""
    @AppStorage("lastDeviceMac") private var lastDeviceMac = ""
    @AppStorage("lastDeviceSnCode") private var lastDeviceSnCode = ""
    @AppStorage("lastDeviceEmoji") private var lastDeviceEmoji = "🚿"

    private var candidates: [DiscoveredPeripheral] {
        scanner.devices.filter { $0.parsedSnCode != nil }
    }

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()
            content
        }
        .sheet(isPresented: $showLog) {
            NavigationStack { LogView() }
        }
        .sheet(isPresented: $showDetail) {
            if let d = selectedDevice {
                DeviceDetailSheet(device: d, colors: colors, onConfirm: {
                    showDetail = false
                    startShower(d)
                })
                .presentationDetents([.medium])
            }
        }
        .task {
            scanner.activeSession = flow.ble
            scanner.start()
        }
        .onChange(of: scanner.devices) { list in
            for d in list {
                guard let sn = d.parsedSnCode else { continue }
                guard resolved[sn] == nil, !resolving.contains(sn) else { continue }
                resolving.insert(sn)
                Task { await resolveDevice(sn) }
            }
        }
        .onDisappear { scanner.stop() }
        .overlay(alignment: .bottom) {
            if let toast {
                LinYuToast(message: toast, isDark: isDark)
                    .padding(.bottom, 120)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: toast) { newValue in
            guard let m = newValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if toast == m { toast = nil }
            }
        }
    }

    // MARK: - 主页内容

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let order = flow.activeOrder {
                    sectionTitle("使用中的设备")
                    activeOrderCard(order)
                } else if !lastDeviceMac.isEmpty {
                    sectionTitle("上次使用设备")
                    lastDeviceCard
                }

                nearbyHeader

                if scanner.isScanning {
                    scanningRow
                }

                if candidates.isEmpty && !scanner.isScanning {
                    emptyHint
                } else {
                    ForEach(candidates) { d in
                        deviceCard(d)
                    }
                }

                if case .failed(let msg) = flow.stage {
                    failureBanner(msg)
                }

                Button {
                    showLog = true
                } label: {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("运行日志")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(colors.textSecondary)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)
                    .padding(14)
                    .linyuCard(colors, radius: 16)
                }
                .buttonStyle(.plain)

                Spacer().frame(height: 110)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: 标题行

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("淋浴")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
                Text("Hualala")
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                iconButton("qrcode.viewfinder") {
                    toast = "iOS 端暂未实现扫码，请从列表选择设备"
                }
                iconButton("arrow.clockwise") {
                    scanner.start()
                }
            }
        }
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundStyle(colors.textPrimary)
                .circleIconBackground(colors)
        }
        .buttonStyle(.plain)
    }

    // MARK: 使用中 / 上次设备

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(colors.textPrimary)
    }

    private func activeOrderCard(_ order: ActiveOrder) -> some View {
        HStack(spacing: 14) {
            DeviceGlyph(
                emoji: order.device.typeEmoji,
                background: DeviceGlyph.background(for: order.device.typeEmoji, colors: colors)
            )

            VStack(alignment: .leading, spacing: 4) {
                TailEllipsisText(
                    text: order.device.displayName,
                    weight: .semibold,
                    color: colors.textPrimary
                )
                HStack(spacing: 8) {
                    Text("使用中")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(colors.activeBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("点击恢复订单")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
            }

            Spacer(minLength: 4)

            Button("恢复") {
                toast = "订单进行中"
            }
            .buttonStyle(AccentButtonStyle(colors: colors))
        }
        .padding(16)
        .background(colors.activeBg)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(colors.border, lineWidth: 0.8)
        )
    }

    private var lastDeviceCard: some View {
        HStack(spacing: 14) {
            DeviceGlyph(
                emoji: lastDeviceEmoji,
                background: DeviceGlyph.background(for: lastDeviceEmoji, colors: colors)
            )

            VStack(alignment: .leading, spacing: 4) {
                TailEllipsisText(
                    text: lastDeviceName.isEmpty ? "热水器" : lastDeviceName,
                    weight: .semibold,
                    color: colors.textPrimary
                )
                TailEllipsisText(
                    text: "MAC: \(lastDeviceMac)",
                    fontSize: 12,
                    color: colors.textSecondary
                )
            }

            Spacer(minLength: 4)

            Button("开始") {
                toast = "请从附近设备里选择"
            }
            .buttonStyle(AccentButtonStyle(colors: colors))
        }
        .padding(16)
        .linyuCard(colors)
    }

    // MARK: 附近设备

    private var nearbyHeader: some View {
        HStack {
            Text("附近设备")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(colors.textPrimary)
            Spacer()
            Text("余额 ¥ —")
                .font(.system(size: 14))
                .foregroundStyle(colors.textSecondary)
        }
        .padding(.top, 4)
    }

    private var scanningRow: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(colors.accent)
                Text("扫描中...")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                LegendDot(color: colors.success, label: "强", textColor: colors.textSecondary)
                LegendDot(color: colors.warning, label: "中", textColor: colors.textSecondary)
                LegendDot(color: colors.danger, label: "弱", textColor: colors.textSecondary)
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Text("未发现热水器")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(colors.textSecondary)
            Text("把手机拿到热水器旁边，几秒内就会出现")
                .font(.system(size: 12))
                .foregroundStyle(colors.textSecondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    private func deviceCard(_ d: DiscoveredPeripheral) -> some View {
        let sn = d.parsedSnCode ?? ""
        let info = resolved[sn]
        let signalColor: Color = d.rssi >= -70 ? colors.success
            : (d.rssi >= -85 ? colors.warning : colors.danger)

        return Button {
            guard let info else {
                toast = "台账里没有这台设备，不能开阀"
                return
            }
            selectedDevice = info
            showDetail = true
        } label: {
            HStack(spacing: 14) {
                DeviceGlyph(
                    emoji: info?.typeEmoji ?? "🚿",
                    background: DeviceGlyph.background(for: info?.typeEmoji ?? "🚿", colors: colors)
                )

                VStack(alignment: .leading, spacing: 5) {
                    TailEllipsisText(
                        text: info?.displayName ?? "SN \(sn)",
                        weight: .semibold,
                        color: colors.textPrimary
                    )
                    Text("信号强度: \(d.rssi) dBm")
                        .font(.system(size: 13))
                        .foregroundStyle(signalColor)
                    Text(sn)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(colors.textSecondary)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.textSecondary)
            }
            .padding(16)
            .linyuCard(colors)
        }
        .buttonStyle(PressableCardStyle())
    }

    private func failureBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(colors.warning)
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(colors.textSecondary)
            Spacer()
        }
        .padding(12)
        .background(colors.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 逻辑

    private var isStopping: Bool {
        if case .closing = flow.stage { return true }
        if case .collecting = flow.stage { return true }
        if case .uploading = flow.stage { return true }
        return false
    }

    private var activeEmoji: String {
        flow.activeOrder?.device.typeEmoji ?? "🚿"
    }

    private var activeStatusText: String {
        flow.activeOrder?.device.statusText ?? "正在沐浴中"
    }

    private var preDeductText: String {
        guard let p = flow.activeOrder?.preDeductMoney, p > 0 else { return "0.00" }
        return String(format: "%.2f", p)
    }

    private func resolveDevice(_ sn: String) async {
        do {
            let data = try await ApiClient.get("/device/info/mac", query: ["macAddress": sn], tag: "deviceInfo")
            let resp = try ApiClient.decode(DeviceInfo.self, from: data, path: "deviceInfo")
            if let info = resp.data {
                resolved[sn] = info
            } else {
                AppLog.shared.w("台账查不到 \(sn)")
            }
        } catch {
            AppLog.shared.w("查台账失败 \(sn)：\(error.localizedDescription)")
        }
        resolving.remove(sn)
    }

    private func startShower(_ device: DeviceInfo) {
        guard let d = scanner.devices.first(where: { $0.parsedSnCode == device.connectMac }),
              let p = scanner.peripheral(for: d.id),
              let central = scanner.manager
        else {
            toast = "设备已不在范围内，请重新扫描"
            return
        }
        scanner.stop()
        lastDeviceName = device.displayName
        lastDeviceMac = device.connectMac
        lastDeviceSnCode = device.snCode ?? ""
        lastDeviceEmoji = device.typeEmoji

        Task {
            await flow.open(device: device, peripheral: p, central: central)
            if flow.activeOrder == nil { scanner.start() }
        }
    }
}

// MARK: - 设备详情弹窗

/// 对照 Android 的 `DeviceDetailDialog.kt`：圆角弹窗 + 若干 `标签 / 值` 行 + 确认按钮。
struct DeviceDetailSheet: View {
    let device: DeviceInfo
    let colors: AppColorSet
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(device.typeEmoji).font(.system(size: 28))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(2)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(colors.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 16)

            VStack(spacing: 10) {
                detailRow("设备类型", device.typeName)
                detailRow("房间", device.displayName)
                detailRow("设备编号", device.snCode ?? "—")
                detailRow("MAC", device.connectMac)
                detailRow("预扣金额", "¥ 5.00")
            }

            Text("开阀后按实际用量结算，预扣金额多退少补。")
                .font(.system(size: 11))
                .foregroundStyle(colors.textSecondary)
                .padding(.top, 14)

            Button(action: onConfirm) {
                Text("开始使用")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(colors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(colors.solidSurface)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(colors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colors.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}
