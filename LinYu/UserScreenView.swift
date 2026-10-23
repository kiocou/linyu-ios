import SwiftUI

/// 「我的」页里可编辑的卡片类型（声明顺序即默认顺序）
enum UserCardType: String, CaseIterable {
    case account
    case useCode
    case notify
    case trend
    case background
    case boundRoom
    case update
    case about
    case log

    var title: String {
        switch self {
        case .account: return "账号信息"
        case .useCode: return "使用码"
        case .notify: return "通知"
        case .trend: return "消费趋势"
        case .background: return "背景装扮"
        case .boundRoom: return "绑定寝室"
        case .update: return "软件更新"
        case .about: return "关于项目"
        case .log: return "运行日志"
        }
    }
}

/// 卡片分页策略 —— 逐条对照 Android 的 `UserCardLayoutPolicy`
enum UserCardLayout {

    /// 「我的」页默认三张
    static let profileDefaults: [UserCardType] = [.account, .useCode, .boundRoom]
    /// 「设置」页默认六张
    static let settingsDefaults: [UserCardType] = [.notify, .trend, .background, .log, .about, .update]

    // 两页一起恢复：卡片移到另一页后不能按各自默认列表过滤回原页。
    // 与 Android restorePages 一致，去重后只补充尚未分配的卡片。
    static func restorePages(profileSaved: String, settingsSaved: String)
        -> (profile: [UserCardType], settings: [UserCardType]) {
        func parse(_ saved: String) -> [UserCardType] {
            saved.split(separator: ",").compactMap {
                UserCardType(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        var assigned = Set<UserCardType>()
        var profile = parse(profileSaved).filter { assigned.insert($0).inserted }
        var settings = parse(settingsSaved).filter { assigned.insert($0).inserted }
        profile += profileDefaults.filter { assigned.insert($0).inserted }
        settings += settingsDefaults.filter { assigned.insert($0).inserted }
        return (profile, settings)
    }

    static func save(_ list: [UserCardType], key: String) {
        UserDefaults.standard.set(list.map(\.rawValue).joined(separator: ","), forKey: key)
    }

    static func saveHidden(_ set: Set<String>, key: String) {
        UserDefaults.standard.set(set.joined(separator: ","), forKey: key)
    }

    static func loadHidden(_ key: String) -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func move<T>(_ list: [T], from: Int, to: Int) -> [T] {
        guard from != to, list.indices.contains(from), list.indices.contains(to) else { return list }
        var m = list
        let item = m.remove(at: from)
        m.insert(item, at: to)
        return m
    }
}

/// 「我的账号」页 —— 逐条对照 Android 的 `UserScreen.kt`。
///
/// 和 Android 一样分两页：
/// - **我的**：账号信息 / 使用码 / 绑定寝室
/// - **设置**：通知 / 消费趋势 / 背景装扮 / 运行日志 / 关于 / 软件更新
///
/// 两页都支持「编辑」：上移、下移、隐藏、移到另一页。
struct UserScreenView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.appColors) private var colors
    @EnvironmentObject private var store: AppDataStore
    @EnvironmentObject private var presentation: UserPresentation
    /// 主题切换的圆形揭示
    @EnvironmentObject private var reveal: ThemeReveal

    @ObservedObject var flow: ShowerFlow
    @ObservedObject var scanner: BLEScanner
    /// 进设置页时底部导航栏要消失（Android 也是这么做的）
    @Binding var settingsVisible: Bool

    @AppStorage("linyu.darkMode") private var isDark = false

    @State private var showSettings = false
    /// 退出登录确认（对照 Android `MainActivity.showLogoutConfirm`）
    @State private var showLogoutConfirm = false
    @State private var editMode = false
    /// 主题按钮在屏幕坐标里的位置（揭示动画的原点）
    @State private var themeAnchor: CGRect = .zero

    @State private var profileOrder: [UserCardType]
    @State private var settingsOrder: [UserCardType]
    @State private var profileHidden: Set<String> = UserCardLayout.loadHidden("userProfileHiddenCards")
    @State private var settingsHidden: Set<String> = UserCardLayout.loadHidden("userSettingsHiddenCards")

    init(flow: ShowerFlow, scanner: BLEScanner, settingsVisible: Binding<Bool>) {
        self.flow = flow
        self.scanner = scanner
        _settingsVisible = settingsVisible
        let pages = UserCardLayout.restorePages(
            profileSaved: UserDefaults.standard.string(forKey: "userProfileCardOrder") ?? "",
            settingsSaved: UserDefaults.standard.string(forKey: "userSettingsCardOrder") ?? ""
        )
        _profileOrder = State(initialValue: pages.profile)
        _settingsOrder = State(initialValue: pages.settings)
    }

    private var versionText: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "?"
        return "Hualala v\(v) · 哗啦啦啦啦让我去淋浴~"
    }

    var body: some View {
        ZStack {
            AppBackground()

            if let page = presentation.page {
                switch page {
                case .background: CustomBackgroundView(onBack: { presentation.page = nil })
                case .log: LogView(onBack: { presentation.page = nil })
                }
            } else if showSettings {
                settingsPage
            } else {
                profilePage
            }
        }
        .onAppear { settingsVisible = showSettings || presentation.page != nil }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onChange(of: showSettings) { v in settingsVisible = v || presentation.page != nil }
        .onChange(of: presentation.page) { page in settingsVisible = showSettings || page != nil }
        .onDisappear { settingsVisible = false }
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard !showLogoutConfirm, presentation.dialog == nil, value.startLocation.x < 24,
                      value.translation.width > 80, abs(value.translation.height) < 50 else { return }
                if presentation.page != nil { presentation.page = nil; return }
                guard showSettings else { return }
                showSettings = false
                editMode = false
            }
        )
        .alert(flow.restoredOrders.isEmpty ? "确认退出" : "无法退出", isPresented: $showLogoutConfirm) {
            if flow.restoredOrders.isEmpty {
                Button("退出", role: .destructive) {
                    guard flow.restoredOrders.isEmpty else { return }
                    showSettings = false
                    flow.reset()
                    session.logout()
                }
                Button("取消", role: .cancel) {}
            } else {
                Button("返回", role: .cancel) {}
            }
        } message: {
            Text(flow.restoredOrders.isEmpty ? "确定退出登录？" : "设备使用中，无法退出")
        }
    }

    // MARK: - 我的

    @ViewBuilder
    private var profilePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(showBack: false)

                cardList(
                    order: $profileOrder,
                    hidden: $profileHidden,
                    orderKey: "userProfileCardOrder",
                    hiddenKey: "userProfileHiddenCards",
                    toOtherIcon: "arrow.right",
                    toOtherHint: "移到设置页面"
                ) { type in
                    moveToSettings(type)
                }

                Color.clear.frame(height: 100)
            }
            .padding(20)
        }
        .clipped()
    }

    // MARK: - 设置

    @ViewBuilder
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(showBack: true)

                cardList(
                    order: $settingsOrder,
                    hidden: $settingsHidden,
                    orderKey: "userSettingsCardOrder",
                    hiddenKey: "userSettingsHiddenCards",
                    toOtherIcon: "arrow.left",
                    toOtherHint: "移到我的页面"
                ) { type in
                    moveToProfile(type)
                }

                // 对照 Android `UserScreen.kt:409`：点击只是把事件往上抛，
                // 真正的确认弹窗在容器层（MainActivity）——iOS 这边同理放在本页 overlay
                Button {
                    showLogoutConfirm = true
                } label: {
                    Text("退出登录")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(colors.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(colors.danger.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(InstantButtonStyle())
                .padding(.top, 8)

                Text(versionText)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
                    .padding(.top, 8)

                Color.clear.frame(height: 100)
            }
            .padding(20)
        }
        .clipped()
    }

    private func header(showBack: Bool) -> some View {
        HStack(alignment: .center) {
            if showBack {
                Button {
                    showSettings = false
                    editMode = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel("返回我的账号")
            }

            Text(showBack ? "设置" : "我的账号")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(colors.textPrimary)

            Spacer()

            Button(editMode ? "完成" : "编辑") {
                editMode.toggle()
            }
            .font(.system(size: 14))
            .foregroundStyle(colors.accent)
            .buttonStyle(InstantButtonStyle())

            if !showBack {
                Button {
                    toggleTheme()
                } label: {
                    Text(isDark ? "🌙" : "☀️")
                        .font(.system(size: 20))
                        .frame(width: 40, height: 40)
                        // 记录按钮在**屏幕坐标**里的位置：揭示动画要以它为中心扩散
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: ThemeAnchorKey.self,
                                    value: g.frame(in: .global)
                                )
                            }
                        )
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel(isDark ? "切换浅色模式" : "切换深色模式")

                Button {
                    showSettings = true
                    editMode = false
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel("打开设置")
            }
        }
        .frame(height: PageLayout.titleHeight)
        .frame(height: PageLayout.headerHeight, alignment: .top)
        .padding(.bottom, 16)
        .onPreferenceChange(ThemeAnchorKey.self) { themeAnchor = $0 }
    }

    /// 切主题：有按钮位置就走圆形揭示，拿不到就退化成直接切（绝不因为动画失败而不切）
    private func toggleTheme() {
        let screen = UIScreen.main.bounds.size
        guard themeAnchor != .zero else {
            isDark.toggle()
            return
        }
        let origin = CGPoint(x: themeAnchor.midX, y: themeAnchor.midY)
        // ⚠️ coverColor 必须是**切换前**的底色：遮罩填的就是它
        reveal.toggle(
            origin: origin,
            coverColor: colors.background,
            screen: screen
        ) {
            isDark.toggle()
        }
    }

    // MARK: - 卡片列表

    @ViewBuilder
    private func cardList(
        order: Binding<[UserCardType]>,
        hidden: Binding<Set<String>>,
        orderKey: String,
        hiddenKey: String,
        toOtherIcon: String,
        toOtherHint: String,
        onMoveToOther: @escaping (UserCardType) -> Void
    ) -> some View {
        let visible = editMode
            ? order.wrappedValue
            : order.wrappedValue.filter { !hidden.wrappedValue.contains($0.rawValue) }

        ForEach(Array(visible.enumerated()), id: \.element) { index, type in
            VStack(alignment: .leading, spacing: 4) {
                if editMode {
                    HStack(spacing: 0) {
                        Text(hidden.wrappedValue.contains(type.rawValue) ? "\(type.title)（已隐藏）" : type.title)
                            .font(.system(size: 13))
                            .foregroundStyle(colors.textSecondary.opacity(
                                hidden.wrappedValue.contains(type.rawValue) ? 0.6 : 1
                            ))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        editIcon(toOtherIcon, toOtherHint, colors.accent) {
                            onMoveToOther(type)
                        }
                        editIcon("chevron.up", "上移", index > 0 ? colors.accent : colors.textSecondary.opacity(0.3), enabled: index > 0) {
                            order.wrappedValue = UserCardLayout.move(order.wrappedValue, from: index, to: index - 1)
                            UserCardLayout.save(order.wrappedValue, key: orderKey)
                        }
                        editIcon("chevron.down", "下移",
                                 index < visible.count - 1 ? colors.accent : colors.textSecondary.opacity(0.3),
                                 enabled: index < visible.count - 1) {
                            order.wrappedValue = UserCardLayout.move(order.wrappedValue, from: index, to: index + 1)
                            UserCardLayout.save(order.wrappedValue, key: orderKey)
                        }
                        let isHidden = hidden.wrappedValue.contains(type.rawValue)
                        editIcon(
                            isHidden ? "eye" : "eye.slash",
                            isHidden ? "显示" : "隐藏",
                            isHidden ? colors.success : colors.textSecondary
                        ) {
                            var s = hidden.wrappedValue
                            if isHidden { s.remove(type.rawValue) } else { s.insert(type.rawValue) }
                            hidden.wrappedValue = s
                            UserCardLayout.saveHidden(s, key: hiddenKey)
                        }
                    }
                }

                card(type)
                    .opacity(editMode && hidden.wrappedValue.contains(type.rawValue) ? 0.45 : 1)
            }
            .padding(.bottom, 16)
        }
    }

    private func editIcon(
        _ symbol: String,
        _ hint: String,
        _ color: Color,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(InstantButtonStyle())
        .accessibilityLabel(hint)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func card(_ type: UserCardType) -> some View {
        switch type {
        case .account: AccountCardView()
        case .useCode: UseCodeCardView()
        case .notify: NotifyCardView()
        case .trend: TrendToggleCardView()
        case .background: BackgroundCardView()
        case .boundRoom: BoundRoomCardView(scanner: scanner, store: store)
        case .update: SoftwareUpdateCard()
        case .about: AboutCardView()
        case .log: LogCardView { presentation.page = .log }
        }
    }

    // MARK: - 跨页移动

    private func moveToSettings(_ type: UserCardType) {
        profileOrder = profileOrder.filter { $0 != type }
        if !settingsOrder.contains(type) { settingsOrder.append(type) }
        profileHidden.remove(type.rawValue)
        settingsHidden.remove(type.rawValue)
        UserCardLayout.save(profileOrder, key: "userProfileCardOrder")
        UserCardLayout.save(settingsOrder, key: "userSettingsCardOrder")
        UserCardLayout.saveHidden(profileHidden, key: "userProfileHiddenCards")
        UserCardLayout.saveHidden(settingsHidden, key: "userSettingsHiddenCards")
    }

    private func moveToProfile(_ type: UserCardType) {
        settingsOrder = settingsOrder.filter { $0 != type }
        if !profileOrder.contains(type) { profileOrder.append(type) }
        profileHidden.remove(type.rawValue)
        settingsHidden.remove(type.rawValue)
        UserCardLayout.save(profileOrder, key: "userProfileCardOrder")
        UserCardLayout.save(settingsOrder, key: "userSettingsCardOrder")
        UserCardLayout.saveHidden(profileHidden, key: "userProfileHiddenCards")
        UserCardLayout.saveHidden(settingsHidden, key: "userSettingsHiddenCards")
    }
}
