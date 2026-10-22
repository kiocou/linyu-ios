import SwiftUI

/// 账单页 —— 对照 Android 的 `WalletScreen.kt`。
///
/// 结构：余额卡片（一卡通 + 钱包）→ 月份切换 → 当月账单列表。
struct WalletScreenView: View {
    @Environment(\.appColors) private var colors

    @State private var month = Self.currentMonth()
    @State private var bills: [BillDTO] = []
    @State private var loading = false
    @State private var walletMoney: Double?
    @State private var campusMoney: Double?
    @State private var campusSigned = false
    @State private var errorText: String?

    private static func currentMonth() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }

    private var monthTotal: Double {
        bills.reduce(0) { $0 + ($1.yuan ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("账单")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.top, 8)

                balanceCard
                monthPicker

                if loading && bills.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView().tint(colors.accent)
                        Spacer()
                    }
                    .padding(.top, 40)
                } else if bills.isEmpty {
                    VStack(spacing: 6) {
                        Text(errorText ?? "本月还没有消费记录")
                            .font(.system(size: 14))
                            .foregroundStyle(colors.textSecondary)
                        if errorText != nil {
                            Button("重试") { Task { await load() } }
                                .font(.system(size: 13))
                                .foregroundStyle(colors.accent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    Text("共 \(bills.count) 笔 · 合计 ¥\(String(format: "%.2f", monthTotal))")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)

                    ForEach(bills) { bill in
                        billRow(bill)
                    }
                }

                Spacer().frame(height: 120)
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .task { await load() }
    }

    // MARK: 余额

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("账户余额")
                .font(.system(size: 12))
                .foregroundStyle(colors.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("¥")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(colors.textPrimary)
                Text(walletMoney.map { String(format: "%.2f", $0) } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(colors.textPrimary)
            }

            Divider().overlay(colors.border)

            HStack(spacing: 16) {
                miniBalance(
                    "校园卡",
                    value: campusMoney.map { String(format: "%.2f", $0) },
                    note: campusSigned ? "已签约免密" : "未签约"
                )
                miniBalance("钱包", value: walletMoney.map { String(format: "%.2f", $0) }, note: "趣智余额")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .linyuCard(colors)
    }

    private func miniBalance(_ title: String, value: String?, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(colors.textSecondary)
            Text(value.map { "¥\($0)" } ?? "—")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(colors.textPrimary)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(colors.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 月份切换

    private var monthPicker: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.accent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(month)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(colors.textPrimary)

            Spacer()

            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(canGoForward ? colors.accent : colors.textSecondary.opacity(0.35))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .linyuCard(colors, radius: 16)
    }

    private var canGoForward: Bool {
        month < Self.currentMonth()
    }

    private func shiftMonth(_ delta: Int) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        guard let d = f.date(from: month),
              let next = Calendar.current.date(byAdding: .month, value: delta, to: d)
        else { return }
        month = f.string(from: next)
        Task { await load() }
    }

    // MARK: 账单行

    private func billRow(_ bill: BillDTO) -> some View {
        HStack(spacing: 14) {
            DeviceGlyph(
                emoji: bill.deviceEmoji,
                boxSize: 42,
                cornerRadius: 12,
                emojiSize: 20,
                background: DeviceGlyph.background(for: bill.deviceEmoji, colors: colors)
            )

            VStack(alignment: .leading, spacing: 4) {
                TailEllipsisText(
                    text: bill.deviceNamePart.isEmpty ? "热水器" : bill.deviceNamePart,
                    weight: .medium,
                    color: colors.textPrimary
                )
                Text(bill.deviceTypeLabel + " · " + (bill.consumeDate?.prefix(16).description ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(bill.yuan.map { String(format: "¥%.2f", $0) } ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(colors.textPrimary)
        }
        .padding(14)
        .linyuCard(colors, radius: 18)
    }

    // MARK: 数据

    private func load() async {
        loading = true
        errorText = nil

        // 余额（两个接口都可以失败，失败就显示 —）
        if let w = try? await ApiClient.get("/account/wallet", tag: "wallet"),
           let wr = try? ApiClient.decode(WalletData.self, from: w, path: "wallet"),
           let data = wr.data {
            walletMoney = data.realYuan ?? data.moneyYuan
        }
        if let c = try? await ApiClient.get("/settlement/campus/userInfo", tag: "campus"),
           let cr = try? ApiClient.decode(CampusUserInfo.self, from: c, path: "campus"),
           let data = cr.data {
            campusMoney = data.yuan
            campusSigned = (data.signStatus == 1)
        }

        // 账单
        do {
            let data = try await ApiClient.get(
                "/order/query/account/bill/list",
                query: ["month": month, "billRequestType": "2"],
                tag: "bills"
            )
            let resp = try ApiClient.decode([BillItem].self, from: data, path: "bills")
            bills = (resp.data ?? []).compactMap { $0.consumeBillDTO }
                .sorted { ($0.consumeDate ?? "") > ($1.consumeDate ?? "") }
        } catch {
            errorText = error.localizedDescription
            bills = []
        }

        loading = false
    }
}
