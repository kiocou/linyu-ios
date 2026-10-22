import CoreBluetooth
import SwiftUI

/// 主界面 —— 逐条对照 Android 的 `MainScreen.kt`。
///
/// 结构（自上而下）：
/// ```
/// 淋浴 / Hualala                    [扫码] [刷新]
/// 使用中的设备 / 上次使用设备
/// 附近设备                          一卡通余额 ¥55.46
/// 🏠 已筛选：3层-320  取消筛选
/// ● 扫描中...                ●强 ●中 ●弱
/// [设备卡片…]
/// ```
struct MainScreenView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.appColors) private var colors
    @Environment(\.isDarkMode) private var isDark

    /// 扫描器由 MainTabView 持有：首页要展示列表，「我的 → 绑定寝室」也要读附近设备，
    /// 两个页面必须共用同一份扫描结果（各建一个会重复扫描、结果还不一致）
    @ObservedObject var scanner: BLEScanner
    /// 由 MainTabView 注入，用水页也在那一层切换
    @ObservedObject var flow: ShowerFlow

    /// snCode → 台账
    @State private var resolved: [String: DeviceInfo] = [:]
    @State private var resolving: Set<String> = []
    @State private var detailDevice: DeviceInfo?
    @State private var showLog = false
    @State private var showQr = false

    /// 账单（余额估算要用）
    @State private var bills: [BillDTO] = []
    @State private var billsLoaded = false
    /// 寝室筛选条件（ViewModel 的等价物：改完要立刻刷新列表）
    @State private var boundRoom = Prefs.boundRoom
    /// 下拉刷新中
    @State private var refreshing = false

    // MARK: - 派生

    /// 能解析出 snCode 的设备（解析不出来的不是这批水表）
    private var scanned: [DiscoveredPeripheral] {
        scanner.devices.filter { $0.parsedSnCode != nil }
    }

    /// 按寝室筛选后的列表
    private var filtered: [DiscoveredPeripheral] {
        guard !boundRoom.isEmpty else { return scanned }
        return scanned.filter { d in
            let sn = d.parsedSnCode ?? ""
            let name = resolved[sn]?.deviceName ?? d.name
            return DeviceInfo.inSameRoom(boundKey: boundRoom, deviceName: name)
        }
    }

    /// 余额：真实余额优先（一卡通 > 钱包），否则本地估算
    private var displayBalance: Double? {
        if BalanceEstimator.hasRealBalance { return BalanceEstimator.realBalance }
        return billsLoaded ? BalanceEstimator.estimate(bills) : nil
    }

    private var balanceText: String {
        guard let b = displayBalance else { return "\(BalanceEstimator.title) ¥ —" }
        return "\(BalanceEstimator.title) \(BalanceEstimator.format(b))"
    }

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 16) {
                    Color.clear.frame(height: 8)
                    header

                    // 使用中的设备
                    if let order = flow.activeOrder {
                        sectionTitle("使用中的设备")
                        activeOrderCard(order)
                    } else if !Prefs.lastDeviceSnCode.isEmpty {
                        sectionTitle("上次使用设备")
                        lastDeviceCard
                    }

                    nearbyHeader

                    if !boundRoom.isEmpty {
                        boundRoomRow
                    }

                    if scanner.isScanning {
                        scanningRow
                    }

                    if scanner.devices.isEmpty && !scanner.isScanning {
                        emptyHint
                    }

                    ForEach(filtered, id: \.id) { d in
                        deviceCard(d)
                    }

                    Color.clear.frame(height: 110)   // 给悬浮导航栏留位置
                }
                .padding(.horizontal, 20)
            }
            // ⚠️ 裁剪：不加的话滚动时内容会画到状态栏/导航栏区域上，
            // 表现为「文字盖住状态栏」。Android 那边是 statusBarsPadding() 保证的，
            // iOS 靠「内容留在安全区内 + 这里裁掉溢出」等价实现。
            .clipped()
        }
        .sheet(isPresented: $showLog) {
            NavigationStack { LogView() }
        }
        .fullScreenCover(isPresented: $showQr) {
            QrScanView { sn in
                showQr = false
                if !sn.isEmpty { Task { await bindBySn(sn) } }
            } onCancel: {
                showQr = false
            }
        }
        .task {
            // 关键：让扫描器把连接事件转发给业务会话（iOS 只能有一个 central）
            scanner.activeSession = flow.ble
            await refreshAll()
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
        // 弹窗全部走**居中卡片**（Material3 AlertDialog 的样子），
        // 不用 .sheet —— 那会从底部升上来，和 Android 完全不一样
        .overlay { dialogLayer }
    }

    // MARK: - 弹窗层

    @ViewBuilder
    private var dialogLayer: some View {
        if let d = detailDevice {
            DeviceDetailDialogView(
                device: d,
                isActive: isDeviceActive(d),
                isOwner: true,
                onDismiss: { detailDevice = nil },
                onConfirm: { confirmOpen(d) }
            )
        }

        if flow.isStarting {
            OpeningDialogView(progress: flow.openingText)
        }

        if let msg = flow.errorMessage {
            ShowerErrorDialogView(message: msg) { flow.clearError() }
        }

        if let d = flow.bleConfirmDevice {
            BleRetryDialogView(
                deviceName: d.displayName,
                onConfirm: { Task { await flow.confirmBleOpen() } },
                onDismiss: { flow.dismissBleConfirm() }
            )
        }

        if let notice = flow.autoClose {
            AutoCloseDialogView(
                deviceName: notice.deviceName,
                elapsedSeconds: notice.elapsedSeconds,
                consumed: notice.consumed,
                loading: notice.loading,
                onConfirm: { flow.dismissAutoClose() }
            )
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("淋浴")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
                Text("Hualala")
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                circleIconButton {
                    showQr = true
                } content: {
                    VectorIconView(icon: DeviceIcons.qrScanner, size: 20, tint: colors.textPrimary)
                }
                circleIconButton {
                    Task { await refreshAll(); scanner.start() }
                } content: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(colors.textPrimary)
                }
            }
        }
    }

    private func circleIconButton<C: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> C
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(colors.card)
                content()
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(PressableCardStyle())
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(colors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 使用中的设备

    private func activeOrderCard(_ order: ActiveOrder) -> some View {
        HStack(spacing: 14) {
            DeviceGlyph(
                emoji: order.device.typeEmoji,
                boxSize: 48,
                cornerRadius: 14,
                emojiSize: 22,
                iconSize: 26,
                background: DeviceGlyph.background(for: order.device.typeEmoji, colors: colors)
            )

            VStack(alignment: .leading, spacing: 4) {
                TailEllipsisText(
                    text: order.device.displayName,
                    fontSize: 15,
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
            Spacer(minLength: 0)

            Button("恢复") {
                // 已经在用这一单，直接回到用水页（activeOrder 本来就在）
                flow.toast = "正在使用中"
            }
            .buttonStyle(AccentButtonStyle(colors: colors))
        }
        .padding(16)
        .linyuCard(colors)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(colors.border, lineWidth: 0.8)
        )
    }

    // MARK: - 上次使用设备

    private var lastDeviceCard: some View {
        HStack(spacing: 14) {
            DeviceGlyph(
                emoji: Prefs.lastDeviceEmoji,
                boxSize: 48,
                cornerRadius: 14,
                emojiSize: 22,
                iconSize: 26,
                background: lastDeviceBackground
            )

            VStack(alignment: .leading, spacing: 4) {
                TailEllipsisText(
                    text: Prefs.lastDeviceName.isEmpty ? "热水器" : Prefs.lastDeviceName,
                    fontSize: 15,
                    weight: .semibold,
                    color: colors.textPrimary
                )
                TailEllipsisText(
                    text: "MAC: \(Prefs.lastDeviceMac)",
                    fontSize: 12,
                    color: colors.textSecondary
                )
            }
            Spacer(minLength: 0)

            Button("开始") {
                Task { await startLastDevice() }
            }
            .buttonStyle(AccentButtonStyle(colors: colors))
        }
        .padding(16)
        .linyuCard(colors)
    }

    private var lastDeviceBackground: Color {
        switch Prefs.lastDeviceEmoji {
        case "🪥": return Color(hex: 0xFFCC80)
        case "❄️", "♨️", "🚰": return Color(hex: 0x10B981)
        default: return Color(hex: 0x2563EB)   // 固定色，不跟随主题
        }
    }

    // MARK: - 附近设备

    private var nearbyHeader: some View {
        HStack {
            Text("附近设备")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(colors.textPrimary)
            Spacer()
            Text(balanceText)
                .font(.system(size: 14))
                .foregroundStyle(colors.textSecondary)
        }
        .padding(.top, 4)
    }

    private var boundRoomRow: some View {
        HStack(spacing: 8) {
            Text("🏠 已筛选：\(DeviceInfo.roomKey(boundRoom) ?? boundRoom)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colors.accent)
            Button {
                boundRoom = ""
                Prefs.boundRoom = ""
                flow.toast = "已取消寝室筛选"
            } label: {
                Text("取消筛选")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private var scanningRow: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(colors.accent)
                    .scaleEffect(0.65)
                    .frame(width: 14, height: 14)
                Text(scanner.stateText.isEmpty ? "扫描中..." : scanner.stateText)
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
        Text(boundRoom.isEmpty ? "未发现热水器" : "未找到寝室内的热水器")
            .font(.system(size: 14))
            .foregroundStyle(colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(32)
    }

    private func deviceCard(_ d: DiscoveredPeripheral) -> some View {
        let sn = d.parsedSnCode ?? ""
        let info = resolved[sn]
        let sigColor: Color = d.rssi >= -70 ? colors.success
            : (d.rssi >= -85 ? colors.warning : colors.danger)
        let sigLabel = d.rssi >= -70 ? "强" : (d.rssi >= -85 ? "中" : "弱")

        return Button {
            Task { await openDetail(sn) }
        } label: {
            HStack(spacing: 14) {
                DeviceGlyph(
                    emoji: info?.typeEmoji ?? "🚿",
                    boxSize: 48,
                    cornerRadius: 14,
                    emojiSize: 22,
                    iconSize: 26,
                    background: info.map { $0.typeColor } ?? colors.accent
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(info?.displayName ?? (d.name.isEmpty ? "未命名设备" : d.name))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("信号\(sigLabel)（\(d.rssi) dBm）")
                        .font(.system(size: 13))
                        .foregroundStyle(sigColor)
                    Text("MAC: \(sn)")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .linyuCard(colors)
        }
        .buttonStyle(PressableCardStyle())
    }

    // MARK: - 数据加载

    private func refreshAll() async {
        refreshing = true
        defer { refreshing = false }

        await BillService.refreshBalances()
        let list = await BillService.loadHistory()
        bills = list
        billsLoaded = true
        boundRoom = Prefs.boundRoom
    }

    /// 查台账
    private func resolveDevice(_ sn: String) async {
        defer { resolving.remove(sn) }
        do {
            let data = try await ApiClient.get(
                "/device/info/mac",
                query: ["macAddress": sn],
                tag: "deviceInfo"
            )
            let resp = try ApiClient.decode(DeviceInfo.self, from: data, path: "deviceInfo")
            if resp.success, let info = resp.data {
                resolved[sn] = info
            } else {
                AppLog.shared.w("台账查不到 \(sn)（success=\(resp.success) data=\(resp.data == nil ? "空" : "有")）")
            }
        } catch {
            AppLog.shared.w("台账请求失败 \(sn)：\(error.localizedDescription)")
        }
    }

    private func openDetail(_ sn: String) async {
        if resolved[sn] == nil {
            await resolveDevice(sn)
        }
        guard let info = resolved[sn] else {
            flow.toast = "查不到这台设备的信息（可能不是本校设备）"
            return
        }
        detailDevice = info
    }

    private func isDeviceActive(_ device: DeviceInfo) -> Bool {
        guard let order = flow.activeOrder else { return false }
        return order.snCode == (device.snCode ?? "")
    }

    /// 详情弹窗里点了「开始使用」
    private func confirmOpen(_ device: DeviceInfo) {
        let sn = device.snCode ?? ""
        let peripheral = scanner.peripheral(forSn: sn)
        let central = scanner.manager

        if device.needsBluetoothControl || Prefs.isBleDevice(sn) {
            guard peripheral != nil else {
                flow.toast = "这台是蓝牙表，需要先扫描到它才能连接"
                return
            }
        }
        Task {
            await flow.open(device: device, peripheral: peripheral, central: central)
        }
    }

    /// 「上次使用设备」→ 开始。
    ///
    /// ⚠️ 这里**不需要扫描到设备**：普通 4G 表走云端，服务端推给设备就行。
    /// 只有蓝牙表（服务端标记 or 用户确认过）才必须有连接对象——那种情况才提示去附近设备里选。
    private func startLastDevice() async {
        let sn = Prefs.lastDeviceSnCode
        guard !sn.isEmpty else {
            flow.toast = "没有上次使用的设备"
            return
        }

        let info: DeviceInfo
        if let cached = resolved[sn] {
            info = cached
        } else {
            do {
                let data = try await ApiClient.get(
                    "/device/info/mac",
                    query: ["macAddress": sn],
                    tag: "deviceInfo"
                )
                let resp = try ApiClient.decode(DeviceInfo.self, from: data, path: "deviceInfo")
                guard resp.success, let d = resp.data else {
                    flow.toast = "获取设备信息失败"
                    return
                }
                resolved[sn] = d
                info = d
            } catch {
                flow.toast = "获取设备信息失败：\(error.localizedDescription)"
                return
            }
        }

        if info.needsBluetoothControl || Prefs.isBleDevice(sn) {
            guard let p = scanner.peripheral(forSn: sn), let central = scanner.manager else {
                flow.toast = "这台是蓝牙表，请从「附近设备」中选它（需要先扫描到）"
                return
            }
            await flow.open(device: info, peripheral: p, central: central)
        } else {
            // 云端通道，不需要连接对象
            await flow.open(device: info, peripheral: nil, central: nil)
        }
    }

    /// 扫码绑定：扫到 snCode 后查台账并直接打开详情
    private func bindBySn(_ sn: String) async {
        await resolveDevice(sn)
        guard let info = resolved[sn] else {
            flow.toast = "未查到该设备（\(sn)）"
            return
        }
        detailDevice = info
    }
}
