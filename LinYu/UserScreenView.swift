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

    static func restore(defaults: [UserCardType], saved: String) -> [UserCardType] {
        guard !saved.isEmpty else { return defaults }
        let allowed = Set(defaults)
        var out = saved.split(separator: ",")
            .compactMap { UserCardType(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { allowed.contains($0) }
        for d in defaults where !out.contains(d) { out.append(d) }
        return out
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

    @ObservedObject var flow: ShowerFlow
    @ObservedObject var scanner: BLEScanner
    /// 进设置页时底部导航栏要消失（Android 也是这么做的）
    @Binding var settingsVisible: Bool

    @AppStorage("linyu.darkMode") private var isDark = false

    @State private var showSettings = false
    @State private var showLog = false
    @State private var editMode = false

    @State private var profileOrder: [UserCardType] = UserCardLayout.restore(
        defaults: UserCardLayout.profileDefaults,
        saved: UserDefaults.standard.string(forKey: "userProfileCardOrder") ?? ""
    )
    @State private var settingsOrder: [UserCardType] = UserCardLayout.restore(
        defaults: UserCardLayout.settingsDefaults,
        saved: UserDefaults.standard.string(forKey: "userSettingsCardOrder") ?? ""
    )
    @State private var profileHidden: Set<String> = UserCardLayout.loadHidden("userProfileHiddenCards")
    @State private var settingsHidden: Set<String> = UserCardLayout.loadHidden("userSettingsHiddenCards")

    private var versionText: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "?"
        return "Hualala v\(v) · 哗啦啦啦啦让我去淋浴~"
    }

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()

            if showSettings {
                settingsPage
            } else {
                profilePage
            }
        }
        .onAppear { settingsVisible = showSettings }
        .onChange(of: showSettings) { v in settingsVisible = v }
        .sheet(isPresented: $showLog) {
            NavigationStack { LogView() }
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

                // ⚠️ 对照 Android：退出登录**没有二次确认弹窗**，
                // 就是一个描边按钮（danger 色、圆角 14、满宽），点了直接退。
                Button {
                    showSettings = false
                    flow.reset()
                    session.logout()
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
                .buttonStyle(.plain)
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
                .buttonStyle(.plain)
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

            if !showBack {
                Button {
                    isDark.toggle()
                } label: {
                    Text(isDark ? "🌙" : "☀️")
                        .font(.system(size: 20))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)

                Button {
                    showSettings = true
                    editMode = false
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 16)
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
                        editIcon("chevron.up", "上移", index > 0 ? colors.accent : colors.textSecondary.opacity(0.3)) {
                            order.wrappedValue = UserCardLayout.move(order.wrappedValue, from: index, to: index - 1)
                            UserCardLayout.save(order.wrappedValue, key: orderKey)
                        }
                        editIcon("chevron.down", "下移",
                                 index < visible.count - 1 ? colors.accent : colors.textSecondary.opacity(0.3)) {
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hint)
    }

    @ViewBuilder
    private func card(_ type: UserCardType) -> some View {
        switch type {
        case .account: AccountCardView()
        case .useCode: UseCodeCardView()
        case .notify: NotifyCardView()
        case .trend: TrendToggleCardView()
        case .background: BackgroundCardView()
        case .boundRoom: BoundRoomCardView(scanner: scanner)
        case .update: UpdateCardView()
        case .about: AboutCardView()
        case .log: LogCardView { showLog = true }
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
