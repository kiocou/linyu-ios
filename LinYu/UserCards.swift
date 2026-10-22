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
    @EnvironmentObject private var session: Session
    @Environment(\.appColors) private var colors

    @State private var info: AccountInfo?
    @State private var projectName: String = ""
    @State private var manageExpanded = false
    @State private var showChangePhone = false
    @State private var showChangePassword = false

    var body: some View {
        BaseCard {
            VStack(alignment: .leading, spacing: 10) {
                // 没值就整行不显示（写死「未设置」既像报错又占位置，
                // 而学校没同步姓名是服务端的事，用户改不了）
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

                Divider().overlay(colors.border)
                    .padding(.top, 2)

                CollapsibleHeader(title: "账号管理", expanded: manageExpanded) {
                    manageExpanded.toggle()
                }

                if manageExpanded {
                    // 对照 Android：两个入口并排（`Arrangement.SpaceEvenly`）
                    HStack {
                        Spacer()
                        Button("更换手机号") { showChangePhone = true }
                            .font(.system(size: 13))
                            .foregroundStyle(colors.accent)
                        Spacer()
                        Button("修改密码") { showChangePassword = true }
                            .font(.system(size: 13))
                            .foregroundStyle(colors.accent)
                        Spacer()
                    }
                }
            }
        }
        .task {
            info = await BillService.loadAccountInfo()
            projectName = await BillService.loadProjectInfo()?.projectName ?? ""
        }
        .overlay {
            if showChangePhone {
                ChangePhoneDialog(
                    currentPhone: Session.shared.telephone,
                    onDismiss: { showChangePhone = false }
                )
            }
            if showChangePassword {
                ChangePasswordDialog(
                    currentPhone: Session.shared.telephone,
                    onDismiss: { showChangePassword = false }
                )
            }
        }
    }
}

// MARK: - 使用码

/// 使用码 —— 逐条对照 Android `UseCodeSection.UseCodeCard`。
struct UseCodeCardView: View {
    @Environment(\.appColors) private var colors
    @State private var data: UseCodeData?
    @State private var loaded = false
    @State private var codeOn = false
    @State private var redeemExpanded = false

    private var code: String? { data?.useCode }
    /// resetAvailability == 0 = 今天已经领过了，服务端不让再领。
    /// 没拉到数据时是 null，按「可以点」处理——让请求自己去报错，好过凭空禁用
    private var canRedeem: Bool { data?.resetAvailability != 0 }

    var body: some View {
        BaseCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("使用码")
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                    Spacer()
                    Text("后三位为手机号后三位")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.textSecondary)
                }

                // 区分「加载中」和「尚未领取」：没领过码的人 useCode 是 null，
                // 一律显示「加载中...」的话永远等不到
                Group {
                    if let code, !code.isEmpty {
                        let prefix = String(code.dropLast(3))
                        let suffix = String(code.suffix(3))
                        (Text(prefix).foregroundColor(colors.textPrimary)
                         + Text(suffix).foregroundColor(colors.accent))
                            .font(.system(size: 28, weight: .black))
                            .tracking(6)
                    } else if loaded {
                        Text("尚未领取")
                            .font(.system(size: 28, weight: .black))
                            .tracking(6)
                            .foregroundStyle(colors.textSecondary)
                    } else {
                        Text("加载中...")
                            .font(.system(size: 28, weight: .black))
                            .tracking(6)
                            .foregroundStyle(colors.textPrimary)
                    }
                }
                .padding(.top, 2)

                HStack {
                    Text(codeOn ? "使用码已开启" : "使用码已关闭")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                    Spacer()
                    Toggle("", isOn: $codeOn)
                        .labelsHidden()
                        .tint(colors.accent)
                        .onChange(of: codeOn) { v in Task { await updateStatus(v) } }
                }
                .padding(.top, 4)

                Text("在热水器物理键盘上输入此码")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)

                // 领取入口收起。⚠️ 今天已领过时**按钮照样能点**（照搬 Android）：
                // 置灰虽然「正确」，但用户看不懂为什么不给点；让他点、然后服务端
                // 回一句「1天只能领取一次使用码」，比一个灰按钮说得多
                Divider()
                    .background(colors.border)
                    .padding(.top, 12)

                Button {
                    redeemExpanded.toggle()
                } label: {
                    HStack {
                        Text(code?.isEmpty == false ? "重新领取" : "领取使用码")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.textPrimary)
                        Spacer()
                        Image(systemName: redeemExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(colors.textSecondary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if redeemExpanded {
                    if !canRedeem, let warn = data?.resetAvailabilityWarMark {
                        Text(warn)
                            .font(.system(size: 11))
                            .foregroundStyle(colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    Button {
                        Task { await redeem() }
                    } label: {
                        Text("领取")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(colors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        // 进程级缓存：切回「我的」页不用再等一次网络
        if let c = UserPageCache.useCode {
            data = c
            codeOn = c.useCodeStatus == 1
            loaded = true
            return
        }
        do {
            let raw = try await ApiClient.get("/account/useCode/new", tag: "useCode")
            let resp = try ApiClient.decode(UseCodeData.self, from: raw, path: "useCode")
            data = resp.data
            codeOn = resp.data?.useCodeStatus == 1
            UserPageCache.useCode = resp.data
        } catch {
            AppLog.shared.w("使用码加载失败：\(error.localizedDescription)")
        }
        loaded = true
    }

    private func updateStatus(_ on: Bool) async {
        do {
            _ = try await ApiClient.post(
                "/account/useCode/new/status/update",
                form: ["useCodeStatus": on ? "1" : "0"],
                tag: "useCodeStatus"
            )
        } catch {
            // 失败要把开关拨回去，否则界面在说谎
            codeOn = !on
            AppLog.shared.w("使用码状态更新失败：\(error.localizedDescription)")
        }
    }

    /// 重新领取。服务端不给时会用 `resetAvailabilityWarMark` 说明原因
    /// （实测是「1天只能领取一次使用码」）
    private func redeem() async {
        do {
            let raw = try await ApiClient.get("/account/useCode/new", tag: "useCodeRedeem")
            let resp = try ApiClient.decode(UseCodeData.self, from: raw, path: "useCodeRedeem")
            data = resp.data
            UserPageCache.useCode = resp.data
            if let c = resp.data { codeOn = c.useCodeStatus == 1 }
            if let warn = resp.data?.resetAvailabilityWarMark, resp.data?.resetAvailability == 0 {
                AppLog.shared.w("领取使用码：\(warn)")
            }
        } catch {
            AppLog.shared.w("领取使用码失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 通知设置

/// ⚠️ iOS 的平台限制必须说清楚：Android 那套「App 被杀也继续监控、发现水被外部关掉就通知」
/// 依赖前台服务，iOS 做不到。所以这里的开关**只影响 App 在前台/刚回前台时的提示**，
/// 界面上要如实写明，不能让用户以为关掉/打开就等于安卓端的效果。
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
                        .onChange(of: enabled) { v in Prefs.notifyEnabled = v }
                }

                if enabled {
                    // ── 展开入口 ──
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
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
                    .buttonStyle(.plain)
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
/// Android 点「更换」会进 `CustomBackgroundScreen`；iOS 这边暂未实现取色与
/// 背景渲染，但**按钮和文案保持一致**，点了提示「暂未支持」而不是干脆不画。
struct BackgroundCardView: View {
    @Environment(\.appColors) private var colors
    @State private var unsupported = false

    var body: some View {
        BaseCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("背景装扮")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    Text(unsupported ? "使用自己的图片打造专属界面" : "使用自己的图片打造专属界面")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
                Spacer()
                Button {
                    unsupported = true
                } label: {
                    Text("更换")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal: 16)
                        .frame(height: 40)
                        .background(colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
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

    /// ⚠️ 读 Prefs 的**当前值**：首页的筛选也读同一个值，改完两边立刻一致
    @State private var boundRoom = Prefs.boundRoom
    @State private var showPicker = false

    /// 附近可选的寝室键（一间一条；同一间的两台设备算出来本来就相等）
    private var roomKeys: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for d in scanner.devices {
            guard let key = DeviceInfo.roomKey(d.name), seen.insert(key).inserted else { continue }
            out.append(key)
        }
        return out
    }

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
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("未绑定寝室，设备列表将显示全部设备")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }

                Button {
                    showPicker = true
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
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                List {
                    if roomKeys.isEmpty {
                        Text("附近还没有扫到设备，先去首页扫描一次")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.textSecondary)
                    } else {
                        ForEach(roomKeys, id: \.self) { key in
                            Button {
                                Prefs.boundRoom = key
                                boundRoom = key
                                showPicker = false
                            } label: {
                                HStack {
                                    Text(key)
                                        .font(.system(size: 15))
                                        .foregroundStyle(colors.textPrimary)
                                    Spacer()
                                    if key == boundRoom {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(colors.accent)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("选择寝室")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭") { showPicker = false }
                    }
                }
            }
            .environment(\.appColors, colors)
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
    @State private var stars: Int?

    var body: some View {
        BaseCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("关于项目")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)

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
                .buttonStyle(.plain)
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
    /// 使用码（含 status / resetAvailability），领取后要跟着更新
    static var useCode: UseCodeData?
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

// MARK: - 软件更新

/// iOS 不能像 Android 那样下载 APK 自安装，所以这里只做「检查 + 打开下载页」。
/// 也不能假装能更新——写清楚是「到 GitHub 下载」。
struct UpdateCardView: View {
    @Environment(\.appColors) private var colors

    @State private var latestTag: String?
    @State private var latestURL: String?
    @State private var checking = false
    @State private var checked = false

    /// .ipa 安装教程。iOS 侧载要自签，必须看教程才知道怎么做
    private static let tutorialURL = URL(
        string: "https://github.com/yehu-imei/Guides/blob/main/Tutorial/.ipa%E7%9A%84%E5%AE%89%E8%A3%85"
    )

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var hasUpdate: Bool {
        guard let tag = latestTag else { return false }
        return tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) != currentVersion
            && compareVersion(tag, currentVersion) > 0
    }

    var body: some View {
        BaseCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("软件更新")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
                Spacer()
                // ⚠️ iOS **不能像 Android 那样下载 apk 直接覆盖安装**——
                // 侧载 ipa 必须自己签名（7 天还得重签），给用户一个下载链接
                // 等于给个装不上的文件。所以这里不提供「去下载」，
                // 一律指向安装教程。
                if let u = Self.tutorialURL {
                    Link(destination: u) {
                        Text("看教程")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(colors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                } else {
                    Button {
                        Task { await check() }
                    } label: {
                        Text(checking ? "检查中…" : "检查")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(colors.accent)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(colors.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(checking)
                }
            }
        }
        .task {
            if !checked { await check() }
        }
    }

    private var statusText: String {
        if let tag = latestTag {
            return hasUpdate ? "有新版本 \(tag)（当前 \(currentVersion)）" : "已是最新（\(currentVersion)）"
        }
        return checked ? "检查失败，请稍后再试" : "当前 \(currentVersion)"
    }

    private func check() async {
        checking = true
        defer {
            checking = false
            checked = true
        }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/yehu-imei/linyu/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                latestTag = obj["tag_name"] as? String
                latestURL = obj["html_url"] as? String
            }
        } catch {
            AppLog.shared.w("检查更新失败：\(error.localizedDescription)")
        }
    }

    /// `v3.1.0` vs `3.0.5` → 3.1.0 更新
    private func compareVersion(_ a: String, _ b: String) -> Int {
        let clean: (String) -> [Int] = { s in
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = clean(a), y = clean(b)
        for i in 0 ..< max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }
}
