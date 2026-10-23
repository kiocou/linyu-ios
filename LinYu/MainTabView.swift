import SwiftUI

/// 三 Tab 容器 —— 对照 Android 的 `MainActivity`。
///
/// - 用水时**整屏**切成 `ShowerScreenView`，不显示底部导航（和 Android 一致）
/// - Tab 切换是弹性左右滑移（Android 用 `AnimatedContent` + spring 420/0.78）
/// - Toast 挂在这一层，因为开阀/结算的提示可能发生在任意 Tab
struct MainTabView: View {
    @Environment(\.appColors) private var colors
    @Environment(\.isDarkMode) private var isDark

    @State private var tab = 0
    /// 会话状态在容器里持有：首页、用水页、我的页共用同一条 BLE 连接
    @StateObject private var flow = ShowerFlow()
    /// 账单/余额缓存（对照 Android 的 MainViewModel：跨页面存活，切换不重载）
    @StateObject private var store = AppDataStore()
    @StateObject private var userPresentation = UserPresentation()
    /// 扫描器放在容器里：首页展示列表、「我的 → 绑定寝室」读附近设备，共用同一份结果
    @StateObject private var scanner = BLEScanner()
    /// 未支付账单 + 手动代扣（对照 Android 的 MainViewModel 同名部分）
    @StateObject private var deduct = DeductService()
    @ObservedObject private var backgrounds = BackgroundStore.shared
    /// 挤号检测（25 秒心跳 + 401/403 识别）—— 对照 Android `startKickWatch`
    @StateObject private var kickWatch = KickWatch()
    @ObservedObject private var notifications = AppNotifications.shared
    @State private var handlingNotification = false
    @Environment(\.scenePhase) private var scenePhase
    /// 进「我的 → 设置」时隐藏底部导航（Android 也是这么做的）
    @State private var settingsVisible = false
    @State private var showerMinimized = false
    /// 翻页方向（旧 tab < 新 tab 时向右滑）—— 对照 Android AnimatedContent 的 forward 判断
    @State private var slideForward = true
    /// 从首页改完设置（寝室筛选等）要让首页刷新，用一个计数器触发
    @State private var refreshToken = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            AppBackground(scope: flow.activeOrder != nil && !showerMinimized ? .shower : .home)

            if let order = flow.activeOrder, !showerMinimized {
                ShowerScreenView(
                    emoji: order.device.typeEmoji,
                    statusText: order.device.statusText,
                    location: order.device.displayName,
                    remaining: flow.remainingText(order),
                    elapsedSec: order.elapsedSeconds,
                    autoDisConSec: order.autoDisConRemain,
                    isStopping: flow.isStopping,
                    onStop: { Task { await flow.close() } },
                    onMinimize: minimizeShower
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 30).onEnded { value in
                        guard value.startLocation.x < 24, value.translation.width > 80,
                              abs(value.translation.height) < 50 else { return }
                        minimizeShower()
                    }
                )
                .transition(.identity)
            } else {
                ZStack {
                    Group {
                        switch tab {
                        case 0:
                            MainScreenView(scanner: scanner, store: store, flow: flow,
                                           onResumeOrder: { showerMinimized = false })
                                .id(refreshToken)
                        case 1:
                            WalletScreenView(store: store, flow: flow, deduct: deduct)
                        default:
                            UserScreenView(flow: flow, scanner: scanner, settingsVisible: $settingsVisible)
                        }
                    }
                    // ⚠️ `.id(tab)` 必不可少：SwiftUI 靠它把「换页」识别成
                    // 一次插入 + 一次移除，才会走下面的 transition。
                    .id(tab)
                    .transition(pageTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !settingsVisible {
                    // 拦截选中动作：先定方向再带弹簧动画改 tab，
                    // 这样插入/移除都拿到同一个方向（对照 Android 的 forward 判断）
                    PillNavBar(currentTab: Binding(
                        get: { tab },
                        set: { newTab in
                            guard newTab != tab else { return }
                            slideForward = newTab > tab
                            withAnimation(Self.pageAnimation) { tab = newTab }
                        }
                    ), colors: backgrounds.colors(colors))
                        .padding(.bottom, 22)
                        .padding(.horizontal, 24)
                        .transition(.identity)
                }
            }

            // Toast：开阀/结算/扫描的提示都走这一条通道。
            //
            // ⚠️ 位置在**顶部**（对照 Android `LinYuToast` 的 Alignment.TopCenter
            // + padding(top = 60.dp)），从上方滑入。放底部会和悬浮导航栏打架，
            // 也和安卓端不一致。
            if let toast = flow.toast, !toast.isEmpty {
                VStack {
                    LinYuToast(message: toast, isDark: isDark)
                        .padding(.top, 60)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                        .allowsHitTesting(false)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // 这一层铺满全屏，但**不能拦点击**：它只是 Toast 的容器
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.18), value: toast)
            }
        }
        // 铺到屏幕最下沿：Android 是 edge-to-edge + 各页面只加 statusBarsPadding，
        // 底部一律不留白。放在这一层，页面内部就不会各自算一遍安全区。
        .ignoresSafeArea(.container, edges: .bottom)
        // ⚠️ 这里**不能**挂容器级 .animation：它会向下传播到所有子视图，
        // 于是「消费趋势折叠」被套上渐隐、「我的 → 编辑」里卡片上下移动被套上
        // 位移动画 —— 用户看到的就是「残影 / 平移」。
        // 需要的动画各自在**自己的视图上**声明（导航栏滑块、Toast 已有）。
        // 背景装扮 / 运行日志：**模态呈现**。
        //
        // ⚠️ 这里必须用 fullScreenCover，不能放在 ZStack 里当普通子视图。
        // Android 这两个页面都是 `Dialog`（`CustomBackgroundScreen` 用
        // `DialogProperties(usePlatformDefaultWidth = false)`），也就是说它们
        // 跑在**独立的窗口**上，天然盖住导航栏、且不受底层任何 overlay 影响。
        // 之前放在 ZStack 里，真机上按钮点不动、也关不掉 —— 模态呈现是
        // 与 Android 一致的做法，同时彻底避开层级问题。
        .fullScreenCover(item: $userPresentation.page) { page in
            switch page {
            case .background:
                CustomBackgroundView(onBack: { userPresentation.page = nil })
            case .log:
                LogView(onBack: { userPresentation.page = nil })
            }
        }
        .overlay { flowDialogs }
        .overlay {
            UserDialogs(scanner: scanner,
                        onRoomSelected: { flow.toast = "已绑定寝室：\($0)" },
                        onUseCodeRedeemed: { flow.toast = "使用码已更新" })
        }
        .environmentObject(store)
        .environmentObject(userPresentation)
        .environment(\.appColors, backgrounds.colors(colors))
        .task {
            if Prefs.notifyEnabled { _ = await AppNotifications.shared.requestPermission() }
        }
        // 把「扫到的 peripheral / central / 设备台账」交给业务层：
        // 首页「恢复订单」要重新走开阀流程，但 CoreBluetooth 只认 CBPeripheral，
        // 业务层自己扫不了——得靠扫描器提供。
        .task {
            flow.peripheralProvider = { [scanner] sn in scanner.peripheral(forSn: sn) }
            flow.centralProvider = { [scanner] in scanner.manager }
            flow.deviceInfoProvider = { [store] sn in store.deviceInfos[sn] }
            await processNotificationActions()
        }
        // 启动时：补结算上一笔待对账 + 拉一次未支付账单（开阀失败弹窗要用）
        .task { await flow.reconcileSettlements() }
        // 订单监控：15 秒一轮查「还在不在用」，结束就收尾（对照 ShowerWatchService）
        .task { flow.startOrderWatch() }
        .task { await deduct.load() }
        .task { deduct.onBillsChanged = { Task { await store.reload() } } }
        // 挤号检测：生命周期跟主界面走，回登录页就停
        .task { kickWatch.start() }
        .onDisappear { kickWatch.stop() }
        // 回前台对齐用水状态（Android 的 `reconcileShowerOnResume`）
        .onChange(of: scenePhase) { phase in
            if phase != .active { flow.stopOrderWatch() }
            guard phase == .active else { return }
            Task {
                // 先处理指定设备的停止请求，不让账单刷新延迟关阀。
                await processNotificationActions()
                await flow.reconcileOnResume()
                await flow.reconcileSettlements()
                await store.reload()
                flow.startOrderWatch()
            }
        }
        // 覆盖冷启动、前台点击通知，以及回调晚于 scenePhase 的情况。
        .onChange(of: notifications.actions) { _ in Task { await processNotificationActions() } }
        .onChange(of: flow.isStarting) { busy in
            if !busy { Task { await processNotificationActions() } }
        }
        .onChange(of: flow.isStopping) { busy in
            if !busy { Task { await processNotificationActions() } }
        }
        .task { await store.loadProfileIfNeeded() }
        .task { await store.loadUseCode() }
        .onDisappear { store.cancelRequests() }
        .onChange(of: flow.settlementRevision) { _ in Task { await store.reload() } }
        // 订单变化（新开阀 / 被清掉）时同步监控任务
        .onChange(of: flow.restoredOrders) { _ in flow.startOrderWatch() }
        .onChange(of: flow.activeOrder?.snCode) { _ in
            showerMinimized = false
            settingsVisible = false
            if flow.activeOrder == nil { tab = 0 }
        }
        .onChange(of: flow.toast) { value in
            guard let msg = value, !msg.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                // 只在还是同一条消息时才清，避免把后来的新消息误关
                if flow.toast == msg { flow.toast = nil }
            }
        }
    }

    @MainActor
    private func processNotificationActions() async {
        guard scenePhase == .active, !handlingNotification else { return }
        handlingNotification = true
        defer { handlingNotification = false }
        while scenePhase == .active, let action = notifications.actions.first {
            guard await flow.handleNotification(action) else { return }
            notifications.consume(action.id)
            if !action.stop, flow.activeOrder?.snCode == action.target.snCode {
                showerMinimized = false
                settingsVisible = false
            }
        }
    }

    /// 批量补扣并给出与 Android 一致的收尾文案
    private func deductAllUnpaid() async {
        let summary = await deduct.deductAll()
        guard let s = summary else {
            flow.toast = "没有可补扣的账单，或正在处理另一笔代扣"
            flow.clearError()
            return
        }
        flow.clearError()
        if s.unknown > 0 && s.ok == 0 && s.failed == 0 {
            flow.toast = "补扣结果未知，请下拉刷新确认后再操作"
        } else if s.unknown > 0 {
            flow.toast = "成功 \(s.ok) 笔、失败 \(s.failed) 笔、\(s.unknown) 笔结果未知"
        } else if s.failed == 0 {
            flow.toast = "补扣成功，再试一次开阀"
        } else if s.ok == 0 {
            flow.toast = s.firstFailReason ?? "补扣失败，请到「钱包」页重试"
        } else {
            flow.toast = "成功 \(s.ok) 笔、失败 \(s.failed) 笔"
        }
        await store.reload()
    }

    /// 与 Android `AnimatedContent` 同一套参数：
    /// `spring(dampingRatio = 0.78, stiffness = 420)` → SwiftUI 的阻尼系数 ≈ 2×0.78×√420
    static let pageAnimation: Animation = .interpolatingSpring(stiffness: 420, damping: 32)

    /// 左右视差滑移 + 淡入淡出（Android：slideIn/OutHorizontally + fadeIn/Out）
    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: slideForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: slideForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func minimizeShower() {
        slideForward = false
        withAnimation(Self.pageAnimation) { tab = 0 }
        settingsVisible = false
        showerMinimized = true
        flow.toast = "已返回主页，设备仍在运行"
    }

    // 用水页返回后可以查看账单和设置，业务提示必须跨页面可见。
    @ViewBuilder
    private var flowDialogs: some View {
        ZStack {
            if flow.isStarting {
                OpeningDialogView(progress: flow.openingText)
            }
            if let msg = flow.errorMessage {
                ShowerErrorDialogView(
                    message: msg,
                    kind: flow.errorKind,
                    // 只有服务端明确拒绝才把未扣账单摆出来：网络异常引导去补扣
                    // 等于让用户为一次掉线白扣钱
                    unpaid: deduct.deductibleBills,
                    deducting: deduct.deductingConsumeDate != nil,
                    onDeductAll: { Task { await deductAllUnpaid() } },
                    onDismiss: { flow.clearError() }
                )
            }
            if let device = flow.bleConfirmDevice {
                BleRetryDialogView(
                    deviceName: device.displayName,
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
    }

}
