import SwiftUI

/// 我的页 —— 对照 Android 的 `UserScreen.kt`（原版 1522 行，这里保留核心结构）。
///
/// 结构：个人信息卡 → 余额 → 功能分组（使用码/账单/设置）→ 关于 → 退出登录。
struct UserScreenView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.appColors) private var colors
    @Environment(\.isDarkMode) private var isDark

    @State private var accountInfo: AccountInfo?
    @State private var projectName: String = ""
    @State private var walletMoney: Double?
    @State private var showLog = false
    @State private var showAbout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("我的")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.top, 8)

                profileCard
                balanceRow

                group("账户") {
                    infoRow("校园卡", value: accountInfo?.cardStatusName ?? "未绑定", icon: "creditcard")
                    infoRow("学号", value: accountInfo?.idCardNumber ?? "—", icon: "number")
                    infoRow("年级班级",
                            value: [accountInfo?.gradeName, accountInfo?.className]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "),
                            icon: "graduationcap")
                }

                group("其他") {
                    rowButton("运行日志", icon: "doc.text.magnifyingglass") { showLog = true }
                    rowButton("关于", icon: "info.circle") { showAbout = true }
                }

                Button(role: .destructive) {
                    session.logout()
                } label: {
                    Text("退出登录")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(colors.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .linyuCard(colors, radius: 16)
                }
                .buttonStyle(.plain)

                Text("淋浴 LinYu · iOS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.textSecondary.opacity(0.7))
                    .frame(maxWidth: .infinity)

                Spacer().frame(height: 120)
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .task { await load() }
        .sheet(isPresented: $showLog) {
            NavigationStack { LogView() }
        }
        .alert("关于", isPresented: $showAbout) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("趣智校园第三方客户端 · iOS\n\n这是一个学习项目，代码完全开源。\n所有界面与逻辑参照 Android 版实现。")
        }
    }

    // MARK: 个人信息

    private var profileCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colors.accent.opacity(0.14))
                .frame(width: 56, height: 56)
                .overlay(
                    Text(initial)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(colors.accent)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
                Text(projectName.isEmpty ? "projectId \(session.projectId)" : projectName)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
            }

            Spacer()
        }
        .padding(18)
        .linyuCard(colors)
    }

    private var initial: String {
        let n = displayName
        return n.isEmpty ? "?" : String(n.prefix(1))
    }

    private var displayName: String {
        if let n = accountInfo?.name, !n.isEmpty { return n }
        if !session.displayName.isEmpty { return session.displayName }
        return "未设置姓名"
    }

    private var balanceRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("钱包余额")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
                Text(walletMoney.map { String(format: "¥%.2f", $0) } ?? "¥ —")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(colors.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(session.telephone)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(colors.textSecondary)
        }
        .padding(18)
        .linyuCard(colors)
    }

    // MARK: 分组

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.textSecondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .linyuCard(colors)
        }
    }

    private func infoRow(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(colors.accent)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(colors.textPrimary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 13))
                .foregroundStyle(colors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func rowButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(colors.accent)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colors.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 数据

    private func load() async {
        if let d = try? await ApiClient.get("/account/info", tag: "accountInfo"),
           let r = try? ApiClient.decode(AccountInfo.self, from: d, path: "accountInfo") {
            accountInfo = r.data
        }
        if let d = try? await ApiClient.get("/project/info/triple", tag: "projectInfo"),
           let r = try? ApiClient.decode(ProjectInfo.self, from: d, path: "projectInfo"),
           let name = r.data?.projectName {
            projectName = name
        }
        if let d = try? await ApiClient.get("/account/wallet", tag: "wallet"),
           let r = try? ApiClient.decode(WalletData.self, from: d, path: "wallet"),
           let data = r.data {
            walletMoney = data.realYuan ?? data.moneyYuan
        }
    }
}
