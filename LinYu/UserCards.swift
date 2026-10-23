import SwiftUI

// MARK: - 统一卡片外观

/// 逐条对照 Android 的 `BaseCard`：22 圆角、半透明、0.8dp 描边、无阴影
struct BaseCard<Content: View>: View {
    @Environment(\.appColors) private var colors
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .linyuCard(colors)
    }
}

/// 折叠区标题行（一行字 + 箭头，整行可点）
struct CollapsibleHeader: View {
    @Environment(\.appColors) private var colors
    let title: String
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(colors.accent)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colors.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}

/// 卡片里的一行「标签 值」
struct InfoRow: View {
    @Environment(\.appColors) private var colors
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(colors.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 账号信息

struct AccountCardView: View {
    @EnvironmentObject private var presentation: UserPresentation
    @EnvironmentObject private var store: AppDataStore
    @EnvironmentObject private var session: Session
    @Environment(\.appColors) private var colors

    private var info: AccountInfo? { store.accountInfo }
    private var projectName: String { store.projectName }
    @State private var manageExpanded = false

    var body: some View {
        BaseCard {
            VStack(alignment: .leading, spacing: 10) {
                if !store.profileLoaded {
                    ForEach(["姓名", "手机号", "学校", "学号"], id: \.self) { label in
                        InfoRow(label: label, value: "加载中...")
                            .redacted(reason: .placeholder)
                    }
                    if let error = store.profileError {
                        Button(error) { Task { await store.loadProfileIfNeeded() } }
                            .font(.system(size: 12)).foregroundStyle(colors.accent)
                    }
                } else {
                if let name = info?.name, !name.isEmpty {
                    InfoRow(label: "姓名", value: name)
                }
                InfoRow(label: "手机号", value: session.telephone)
                if !projectName.isEmpty {
                    InfoRow(label: "学校", value: projectName)
                }
                if let sid = info?.idCardNumber, !sid.isEmpty {
                    InfoRow(label: "学号", value: sid)
                }
                }

                Divider().overlay(colors.border)
                    .padding(.top, 2)

                CollapsibleHeader(title: "账号管理", expanded: manageExpanded) {
                    manageExpanded.toggle()
                }

                if manageExpanded {
                    // 对照 Android：两个入口并排（`Arrangement.SpaceEvenly`）
                    HStack {
                        Spacer()
                        Button("更换手机号") { presentation.dialog = .phone }
                            .font(.system(size: 13))
                            .foregroundStyle(colors.accent)
                        Spacer()
                        Button("修改密码") { presentation.dialog = .password }
                            .font(.system(size: 13))
                            .foregroundStyle(colors.accent)
                        Spacer()
                    }
                }
            }
        }
        .task {
            await store.loadProfileIfNeeded()
        }

    }
}

// MARK: - 使用码

/// 使用码 —— 逐条对照 Android `UseCodeSection.UseCodeCard`。
struct UseCodeCardView: View {
    @EnvironmentObject private var presentation: UserPresentation
    @EnvironmentObject private var store: AppDataStore
    @Environment(\.appColors) private var colors
    @State private var redeemExpanded = false
    @State private var errorText: String?
    @State private var localCodeOn = false
    private var code: String { store.useCode?.useCode ?? "" }
    var body: some View {
        BaseCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("使用码").font(.system(size: 13))
                    Spacer()
                    Text("后三位为手机号后三位").font(.system(size: 11))
                }.foregroundStyle(colors.textSecondary)
                Spacer().frame(height: 4)
                Group {
                    if !code.isEmpty {
                        (Text(String(code.dropLast(3))).foregroundColor(colors.textPrimary)
                         + Text(String(code.suffix(3))).foregroundColor(colors.accent))
                    } else {
                        Text(store.useCodeLoaded ? "尚未领取" : "加载中...")
                            .foregroundColor(store.useCodeLoaded ? colors.textSecondary : colors.textPrimary)
                    }
                }.font(.system(size: 28, weight: .black)).tracking(6)
                Spacer().frame(height: 4)
                Toggle(localCodeOn ? "使用码已开启" : "使用码已关闭",
                       isOn: Binding(get: { localCodeOn }, set: { enabled in
                    localCodeOn = enabled
                    Task {
                        do { try await store.setUseCodeEnabled(enabled) }
                        catch { localCodeOn = !enabled; errorText = "操作失败，请重试" }
                    }
                }))
                .font(.system(size: 12)).tint(colors.accent)
                .foregroundStyle(colors.textSecondary)
                .frame(minHeight: 48)
                .disabled(store.changingUseCodeStatus)
                Text("在热水器物理键盘上输入此码").font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
                Spacer().frame(height: 12)
                Rectangle().fill(colors.border).frame(height: 1)
                CollapsibleHeader(title: code.isEmpty ? "领取使用码" : "重新领取", expanded: redeemExpanded) {
                    redeemExpanded.toggle()
                }
                if redeemExpanded {
                    if store.useCode?.resetAvailability == 0, let warning = store.useCode?.resetAvailabilityWarMark {
                        Text(warning).font(.system(size: 11)).foregroundStyle(colors.textSecondary)
                            .frame(maxWidth: .infinity)
                        Spacer().frame(height: 6)
                    }
                    Button { presentation.dialog = .useCode } label: {
                        Text(code.isEmpty ? "领取使用码" : "重新领取")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentButtonStyle(colors: colors, radius: 12, height: 40))
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { localCodeOn = store.useCode?.useCodeStatus == 1 }
        .onChange(of: store.useCode?.useCodeStatus) { value in
            if let value { localCodeOn = value == 1 }
        }
        .task { await store.loadUseCode() }
        .alert("操作失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("知道了", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }
}

// MARK: - 通知设置

/// 通知设置卡片 —— 逐条对照 Android `UserSettingsCards.NotifyCard`。
struct NotifyCardView: View {
    @Environment(\.appColors) private var colors

    @State private var enabled = Prefs.notifyEnabled
    @State private var expanded = false
    @State private var inUse = Prefs.notifyInUse
    @State private var finished = Prefs.notifyFinished
    @State private var autoClose = Prefs.notifyAutoClose
    @State private var alert = Prefs.notifyAlert

    var body: some View {
        BaseCard {
            VStack(alignment: .leading, spacing: 0) {
                // ── 总开关 ──
                //
                // ⚠️ 布局是「文字靠左、开关靠右」（Android 的 SpaceBetween）。
                // 之前两边一起居中，开关会跟着文字宽度飘，看着不像设置项。
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("通知")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(colors.textPrimary)
                        Text(enabled ? "用水期间和结束时收到系统提醒" : "已关闭全部通知")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.textSecondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .tint(colors.accent)
                        .onChange(of: enabled) { value in
                            Prefs.notifyEnabled = value
                            if value {
                                Task {
                                    if !(await AppNotifications.shared.requestPermission()) { enabled = false }
                                }
                            } else { AppNotifications.shared.clear() }
                        }
                }

                if enabled {
                    // ── 展开入口 ──
                    Button {
                        expanded.toggle()
                    } label: {
                        HStack {
                            Text("详细设置")
                                .font(.system(size: 13))
                                .foregroundStyle(colors.accent)
                            Spacer()
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(colors.accent)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(InstantButtonStyle())
                    .padding(.top, 10)

                    if expanded {
                        // 文案逐条照搬 Android 的 NotifyRow（标题 + 说明 + 开关靠右）
                        notifyRow("用水状态通知", "使用期间在通知栏显示已用时间", $inUse) { Prefs.notifyInUse = $0 }
                        notifyRow("使用结束通知", "停止后显示用时和消费金额", $finished) { Prefs.notifyFinished = $0 }
                        notifyRow("自动关停提醒", "设备超时自己关闭时提醒", $autoClose) { Prefs.notifyAutoClose = $0 }
                        notifyRow("横幅提醒", "开阀失败、设备被占用时从屏幕顶部弹出", $alert) { Prefs.notifyAlert = $0 }
                    }
                }
            }
        }
    }

    /// 一条细分开关：**标题 + 说明在左，开关固定在右**
    private func notifyRow(
        _ title: String,
        _ desc: String,
        _ value: Binding<Bool>,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textPrimary)
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(colors.textSecondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: value)
                .labelsHidden()
                .tint(colors.accent)
                .onChange(of: value.wrappedValue) { v in onChange(v) }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 消费趋势开关

struct TrendToggleCardView: View {
    @Environment(\.appColors) private var colors
    @State private var enabled = Prefs.trendEnabled

    var body: some View {
        BaseCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("消费趋势")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    Text(enabled ? "账单页显示趋势图" : "账单页不显示趋势图")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .tint(colors.accent)
                    .onChange(of: enabled) { v in Prefs.trendEnabled = v }
            }
        }
    }
}

// MARK: - 背景装扮

/// 背景装扮 —— 逐条对照 Android `UserScreen.BackgroundCard`。
///
/// 主页和使用页分别保存图片与效果。
struct BackgroundCardView: View {
    @Environment(\.appColors) private var colors
    @EnvironmentObject private var presentation: UserPresentation

    var body: some View {
        BaseCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("背景装扮")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    Text("使用自己的图片打造专属界面")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
                Spacer()
                Button {
                    presentation.page = .background
                } label: {
                    Text("更换")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(InstantButtonStyle())
            }
        }
    }
}

// MARK: - 绑定寝室

/// 绑定寝室 —— 逐条对照 Android `UserScreen.BoundRoomCard`。
///
/// ⚠️ 只有「选择附近」一条路，**没有手工输入框**（Android 注释：手工输入存的
/// 是没和设备名核对过的字符串，筛不出来时用户分不清是"输错了"还是"这层真没设备"）。
struct BoundRoomCardView: View {
    @Environment(\.appColors) private var colors
    @ObservedObject var scanner: BLEScanner
    @ObservedObject var store: AppDataStore

    /// ⚠️ 读 Prefs 的**当前值**：首页的筛选也读同一个值，改完两边立刻一致
    @AppStorage("boundRoom") private var boundRoom = ""
    @EnvironmentObject private var presentation: UserPresentation

    var body: some View {
        BaseCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("绑定寝室")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)

                if !boundRoom.isEmpty {
                    HStack {
                        // 存的就是寝室键本身。外面再套一次 roomKey 是为了兼容
                        // 老版本存下来的值（可能是 `320房` 或完整设备名）
                        Text("🏠 \(DeviceInfo.roomKey(boundRoom) ?? boundRoom)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
                            Prefs.boundRoom = ""
                            boundRoom = ""
                        } label: {
                            Text("取消绑定")
                                .font(.system(size: 12))
                                .foregroundStyle(colors.danger)
                        }
                        .buttonStyle(InstantButtonStyle())
                    }
                } else {
                    Text("未绑定寝室，设备列表将显示全部设备")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }

                Button {
                    presentation.dialog = .room
                } label: {
                    Text("选择附近")
                        .font(.system(size: 14))
                        .foregroundStyle(colors.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(colors.border, lineWidth: 1)
                        )
                }
                .buttonStyle(InstantButtonStyle())
                .padding(.top, 4)
            }
        }

    }
}

// MARK: - 运行日志

struct LogCardView: View {
    @Environment(\.appColors) private var colors
    let onOpen: () -> Void

    var body: some View {
        BaseCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("运行日志")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    Text("查看/导出运行日志，便于排查问题")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
                Spacer()
                Button("查看", action: onOpen)
                    .buttonStyle(AccentButtonStyle(colors: colors, radius: 14))
            }
        }
    }
}

// MARK: - 关于

/// 关于项目 —— 逐条对照 Android `UserScreen.AboutCard`。
///
/// Star 数来自 GitHub API；拉不到就**省略**，不显示假数据。
struct AboutCardView: View {
    @Environment(\.appColors) private var colors
    @State private var stars: Int? = UserPageCache.stars

    var body: some View {
        BaseCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("关于项目")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.bottom, 4)

                Text("一款趣智校园第三方客户端")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)

                Text("项目名：淋浴（Hualala）" + (stars.map { " · ⭐ \($0)" } ?? ""))
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)

                Text("制作者：yehu-imei")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)

                HStack(spacing: 0) {
                    Text("联系方式：")
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                    Link("2276391153@qq.com", destination: URL(string: "mailto:2276391153@qq.com")!)
                        .font(.system(size: 13))
                }

                Button {
                    if let u = URL(string: "https://github.com/yehu-imei/linyu") {
                        UIApplication.shared.open(u)
                    }
                } label: {
                    Text("访问 GitHub 仓库")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(InstantButtonStyle())
                .padding(.top, 8)
            }
        }
        .task {
            guard stars == nil else { return }
            // 用进程级缓存，避免每次切到「我的」都重新请求
            if let v = UserPageCache.stars { stars = v; return }
            let v = await GithubInfo.fetchStars()
            UserPageCache.stars = v
            stars = v
        }
    }
}

/// 「我的」页的进程级缓存 —— 对照 Android 的 `UserPageCache`。
///
/// 页面切 tab 时会被重建，不缓存的话每次切回来都要重新发 GitHub 请求，
/// 表现为「卡片先空一下再出现内容」。
enum UserPageCache {
    static var stars: Int?
}

enum GithubInfo {
    /// 拉仓库 Star 数。失败返回 nil（调用方负责省略，不显示假数据）
    static func fetchStars() async -> Int? {
        guard let url = URL(string: "https://api.github.com/repos/yehu-imei/linyu") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["stargazers_count"] as? Int
        } catch {
            AppLog.shared.w("拉取仓库信息失败：\(error.localizedDescription)")
            return nil
        }
    }
}
