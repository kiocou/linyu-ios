import SwiftUI

/// 账单页 —— 逐条对照 Android 的 `WalletScreen.kt`。
///
/// 自上而下：余额标题 → 余额卡 → 消费趋势 → 账单（**最近 20 次**）→ 账单详情弹窗。
struct WalletScreenView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.appColors) private var colors

    /// 账单/余额由容器层持有（对照 Android 的 MainViewModel），
    /// 页面切走再切回来不会重新请求
    @ObservedObject var store: AppDataStore
    @ObservedObject var flow: ShowerFlow

    @State private var detailBill: BillDTO?
    @State private var showEditDialog = false
    @State private var editValue = ""
    @State private var trendEnabled = Prefs.trendEnabled

    /// 列表只显示最近 20 次（对照 Android 的 `billList = all.take(20)`）
    private var recent: [BillDTO] { Array(store.bills.prefix(20)) }

    private var displayBalance: Double? {
        if BalanceEstimator.hasRealBalance { return BalanceEstimator.realBalance }
        return store.loaded ? BalanceEstimator.estimate(store.bills) : nil
    }

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 标题按**钱在哪**写：一卡通 → 「一卡通余额」，钱包 → 「趣智校园余额」
                    Text(BalanceEstimator.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(colors.textPrimary)

                    balanceCard
                        .padding(.top, 16)

                    if trendEnabled {
                        SpendingTrendCard(bills: store.bills, loading: store.loading && !store.loaded)
                            .padding(.top, 24)
                    }

                    Text("账单")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(colors.textPrimary)
                        .padding(.top, 24)
                    Text("最近20次消费记录")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                        .padding(.top, 2)

                    if store.loading && !store.loaded {
                        HStack {
                            Spacer()
                            ProgressView().tint(colors.accent)
                            Spacer()
                        }
                        .padding(24)
                    } else if recent.isEmpty {
                        Text("暂无账单数据")
                            .font(.system(size: 14))
                            .foregroundStyle(colors.textSecondary)
                            .padding(.top, 12)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(recent) { bill in
                                billCard(bill)
                            }
                        }
                        .padding(.top, 12)
                    }

                    Color.clear.frame(height: 100)   // 给悬浮导航栏留位置
                }
                .padding(20)
            }
            .clipped()
            .refreshable { await store.reload() }
        }
        .task { await load() }
        .onAppear { trendEnabled = Prefs.trendEnabled }
        .overlay {
            if let b = detailBill {
                billDetailDialog(b)
            }
            if showEditDialog {
                manualBalanceDialog
            }
        }
    }

    // MARK: - 余额卡

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("账户余额 (元)")
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textSecondary)
                Spacer()
                // 拿到真实余额后「手动填写」就藏起来：估算值会被真实值覆盖，
                // 摆在那儿只会让人以为填了能改数字
                if !BalanceEstimator.hasRealBalance {
                    Button {
                        // 预填**当前显示的余额**，不是上次填的初始值
                        editValue = displayBalance.map { MoneyFormat.format($0) }
                            ?? (Prefs.manualBalance.isEmpty ? "0" : Prefs.manualBalance)
                        showEditDialog = true
                    } label: {
                        Text("手动填写")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(displayBalance.map { "¥ \(MoneyFormat.format($0))" } ?? "¥ —")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(colors.textPrimary)
                .padding(.top, 4)

            Text(BalanceEstimator.sourceText)
                .font(.system(size: 11))
                .foregroundStyle(colors.textSecondary)
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .linyuCard(colors)
    }

    // MARK: - 账单卡片

    private func billCard(_ bill: BillDTO) -> some View {
        let typeColor: Color = bill.isDrinkingWaterBill
            ? Color(hex: 0x10B981)
            : (bill.deviceTypeLabel.contains("洗手台") ? Color(hex: 0xFF9800) : colors.accent)

        return Button {
            detailBill = bill
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(bill.deviceEmoji) \(bill.displayNamePart)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(bill.deviceTypeLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(typeColor)
                    Text(String((bill.consumeDate ?? "").prefix(16)))
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
                Spacer(minLength: 12)
                Text("-¥ \(bill.consumeMoney ?? "0")")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(colors.danger)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .linyuCard(colors, radius: 14)
        }
        .buttonStyle(PressableCardStyle())
    }

    // MARK: - 弹窗

    private func billDetailDialog(_ dto: BillDTO) -> some View {
        DialogScrim(onTapOutside: { detailBill = nil }) {
            AlertCard(title: "账单详情", titleAlign: .leading) {
                VStack(spacing: 0) {
                    DetailRowView(label: "设备名", value: dto.displayNamePart)
                    DetailRowView(label: "设备类型", value: dto.deviceTypeLabel)
                    DetailRowView(label: "消费金额", value: "-¥ \(dto.consumeMoney ?? "0")")
                    DetailRowView(label: "消费时间", value: String((dto.consumeDate ?? "").prefix(19)))
                    DetailRowView(label: "订单号", value: dto.orderId ?? "-")
                }
            } actions: {
                DialogFilledButton(title: "确定", color: colors.accent) { detailBill = nil }
            }
        }
    }

    private var manualBalanceDialog: some View {
        DialogScrim(onTapOutside: { showEditDialog = false }) {
            AlertCard(title: "手动填写余额", titleAlign: .leading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("请输入账户当前余额")
                        .font(.system(size: 14))
                        .foregroundStyle(colors.textSecondary)
                    Text("此操作仅用于本地估算，不会修改账户真实余额")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.textSecondary)
                    TextField("余额 (元)", text: $editValue)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 8)
                }
            } actions: {
                DialogTextButton(title: "取消", color: colors.accent) { showEditDialog = false }
                DialogFilledButton(title: "保存", color: colors.accent) {
                    Prefs.manualBalance = editValue
                    Prefs.manualBalanceTime = Date().timeIntervalSince1970 * 1000
                    showEditDialog = false
                }
            }
        }
    }

    // MARK: - 加载

    private func load() async {
        await store.loadIfNeeded()
        trendEnabled = Prefs.trendEnabled
    }
}
