import SwiftUI

// MARK: - 弹窗基础设施
//
// Android 用的是 Material3 `AlertDialog`：**居中卡片**、28dp 圆角、24dp 内边距、
// 按钮在右下角。iOS 的 `.alert` 只能放系统样式、`.sheet` 从底部升上来——
// 两者都和 Android 长得不一样，所以这里手工复刻一个居中卡片。

/// 遮罩 + 居中容器。点遮罩是否关闭由 `onTapOutside` 决定（null = 不能关）。
struct DialogScrim<Content: View>: View {
    var onTapOutside: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { onTapOutside?() }
                // 不允许点外部关闭的弹窗也必须挡住底层按钮。
                .allowsHitTesting(true)

            content
                .padding(.horizontal, 28)
        }
        // ⚠️ 关键：容器本身也要铺满整个窗口。
        // 只给里面的 Color 加 ignoresSafeArea 不够 —— ZStack 仍会被父视图
        // 按安全区布局，遮罩就只在中间一块（真机反馈：四周露出没压暗的区域）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // 不允许点外部关闭的弹窗也必须拦住底层点击
        .contentShape(Rectangle())
    }
}

/// Material3 AlertDialog 的卡片外壳
struct AlertCard<Content: View, Actions: View>: View {
    @Environment(\.appColors) private var colors

    let title: String
    var titleEmoji: String? = nil
    var titleAlign: TextAlignment = .center
    /// 标题下面那行小字（如位置）
    var subtitle: String? = nil
    var cornerRadius: CGFloat = 28
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题区
            VStack(alignment: titleAlign == .center ? .center : .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let titleEmoji {
                        Text(titleEmoji).font(.system(size: 22))
                    }
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(colors.textPrimary)
                        .multilineTextAlignment(titleAlign)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.gray)
                        .multilineTextAlignment(titleAlign)
                }
            }
            .frame(maxWidth: .infinity, alignment: titleAlign == .center ? .center : .leading)

            content
                .padding(.top, 16)

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                actions
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(colors.solidSurface)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
    }
}

/// Material 风格的文字按钮
struct DialogTextButton: View {
    let title: String
    var color: Color
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(enabled ? color : color.opacity(0.4))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Material 风格的实心按钮（弹窗确认用）
struct DialogFilledButton: View {
    let title: String
    var color: Color
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 40)
                .background(enabled ? color : color.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 详情行：左标签右值（对照 Android 的 `DetailRow` / `WDetailRow`）
struct DetailRowView: View {
    @Environment(\.appColors) private var colors
    let label: String
    let value: String
    var labelColor: Color? = nil
    var valueWeight: Font.Weight = .regular

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(labelColor ?? colors.textPrimary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: valueWeight))
                .foregroundStyle(labelColor == nil ? colors.textPrimary : colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 设备详情弹窗（对照 DeviceDetailDialog.kt）

struct DeviceDetailDialogView: View {
    @Environment(\.appColors) private var colors
    let device: DeviceInfo
    let isActive: Bool
    let isOwner: Bool
    let onDismiss: () -> Void
    let onConfirm: () -> Void

    private var typeLabel: String {
        if device.isDrinkingWater {
            return device.isHotWater ? "饮水（热水）" : "饮水（冷水）"
        }
        return device.typeName == "洗手台" ? "洗漱" : "沐浴"
    }

    private var startText: String {
        device.isDrinkingWater ? "开始接水" : "开始使用"
    }

    var body: some View {
        DialogScrim(onTapOutside: onDismiss) {
            AlertCard(
                title: typeLabel,
                titleEmoji: device.typeEmoji,
                titleAlign: .center,
                subtitle: device.displayName
            ) {
                VStack(spacing: 0) {
                    DetailRowView(label: "类型", value: device.typeName)
                    DetailRowView(label: "SN 码", value: device.snCode ?? "-")
                    DetailRowView(label: "MAC 地址", value: device.macAddress ?? "-")
                    DetailRowView(label: "预扣金额", value: MoneyFormat.withSymbol(device.withholdYuan))
                    DetailRowView(label: "状态", value: isActive ? "使用中" : "空闲")
                    if device.needsBluetoothControl {
                        Text("此设备通过手机蓝牙直连控制：开启后请留在设备旁，走远会断开连接、无法关闭。")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.textSecondary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                    }
                }
            } actions: {
                DialogTextButton(title: "取消", color: colors.accent, action: onDismiss)
                let canUse = !isActive || isOwner
                let txt: String = {
                    if isActive && !isOwner { return "他人使用中" }
                    if isActive { return "恢复使用" }
                    return startText
                }()
                DialogFilledButton(
                    title: txt,
                    color: canUse ? colors.accent : colors.textSecondary,
                    enabled: canUse
                ) {
                    if canUse { onConfirm(); onDismiss() }
                }
            }
        }
    }
}

// MARK: - 正在开启（对照 MainScreen 的 isStartingShower AlertDialog）

struct OpeningDialogView: View {
    @Environment(\.appColors) private var colors
    /// 具体进度文案。蓝牙表那条要好几步，不给进度用户会以为卡死
    let progress: String

    var body: some View {
        DialogScrim(onTapOutside: nil) {
            AlertCard(title: "正在开启热水器...", titleAlign: .center) {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(colors.accent)
                    Text(progress.isEmpty ? "正在确认设备是否开启，请稍候" : progress)
                        .font(.system(size: 14))
                        .foregroundStyle(colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
            } actions: {
                EmptyView()
            }
        }
    }
}

// MARK: - 开阀失败

struct ShowerErrorDialogView: View {
    @Environment(\.appColors) private var colors
    let message: String
    /// 服务端**明确拒绝**才可能和欠费有关。
    ///
    /// ⚠️ 网络异常、设备被占用、结果未知都跟账单无关 —— 把它们也引导到「补扣」，
    /// 用户会因为一次 WiFi 掉线去白扣钱。
    var kind: ShowerErrorKind = .other
    /// 可补扣的未支付账单（只在 `kind == .serverRejected` 时传）
    var unpaid: [UnpaidBill] = []
    var deducting: Bool = false
    var onDeductAll: () -> Void = {}
    let onDismiss: () -> Void

    /// 扣钱前的二次确认态。key 跟着错误内容走，换一条错误就复位
    @State private var confirming = false

    /// 金额是服务端给的**字符串**，解析不出来时**不能悄悄按 0 算**：
    /// 这张弹窗存在的唯一目的就是「会动钱，再停一下」，数字失真就失去意义了
    private var amounts: [Double?] { unpaid.map { $0.yuan } }
    private var total: Double { amounts.reduce(0) { $0 + ($1 ?? 0) } }
    private var amountKnown: Bool { amounts.allSatisfy { $0 != nil } }

    private var shownBills: [UnpaidBill] { kind == .serverRejected ? unpaid : [] }

    var body: some View {
        ZStack {
            DialogScrim(onTapOutside: onDismiss) {
                AlertCard(title: shownBills.isEmpty ? "开阀失败" : "开阀失败 · 有未扣账单",
                          titleAlign: .leading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(message)
                            .font(.system(size: 14))
                            .foregroundStyle(colors.textPrimary)

                        if !shownBills.isEmpty {
                            Text("检测到 \(shownBills.count) 笔没扣成功的账单：")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(colors.warning)
                                .padding(.top, 12)
                            ForEach(shownBills) { bill in
                                Text("· ¥\(bill.consumeMoney ?? "?")   \(String((bill.consumeDate ?? "").prefix(16)))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(colors.textSecondary)
                                    .padding(.top, 4)
                            }
                            Text("账户有欠费时服务端会拒绝开阀")
                                .font(.system(size: 11))
                                .foregroundStyle(colors.textSecondary)
                                .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } actions: {
                    if shownBills.isEmpty {
                        DialogTextButton(title: "知道了", color: colors.accent, action: onDismiss)
                    } else {
                        DialogTextButton(title: "关闭", color: colors.accent, action: onDismiss)
                        DialogFilledButton(title: "立即补扣", color: colors.warning) {
                            confirming = true
                        }
                    }
                }
            }

            // 扣钱前的二次确认（和钱包页单笔代扣共用同一个组件，文案不会各写一份）
            if confirming {
                DeductConfirmDialogView(
                    amount: amountKnown ? total : nil,
                    detail: "共 \(shownBills.count) 笔",
                    onConfirm: {
                        confirming = false
                        onDeductAll()
                    },
                    onDismiss: { confirming = false }
                )
            }
        }
    }
}

// MARK: - 306 → 是否改用蓝牙（对照 MainScreen 的 bleRetryDevice）

struct BleRetryDialogView: View {
    @Environment(\.appColors) private var colors
    let deviceName: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        DialogScrim(onTapOutside: onDismiss) {
            AlertCard(title: "要用蓝牙方式开启吗？", titleAlign: .center) {
                Text("「\(deviceName)」无法通过云端开启。\n\n如果这台设备需要手机蓝牙直连（开启时必须待在设备旁边），可以改用蓝牙方式。\n\n不确定的话：用官方「趣智校园」试一下——需要站到设备旁才能开的就是这一类。")
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textSecondary)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } actions: {
                DialogTextButton(title: "取消", color: colors.accent, action: onDismiss)
                DialogFilledButton(title: "用蓝牙开启", color: colors.accent, action: onConfirm)
            }
        }
    }
}

// MARK: - 自动关停（对照 MainScreen 的 showAutoCloseDialog）

struct AutoCloseDialogView: View {
    @Environment(\.appColors) private var colors
    let deviceName: String
    let elapsedSeconds: Int
    let consumed: Double?
    let loading: Bool
    let onConfirm: () -> Void

    private var elapsedText: String {
        let m = elapsedSeconds / 60, s = elapsedSeconds % 60
        return m > 0 ? "\(m)分\(s)秒" : "\(s)秒"
    }

    var body: some View {
        DialogScrim(onTapOutside: nil) {
            AlertCard(title: "⚠️ 热水器已自动关闭", titleAlign: .center) {
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("🚿").font(.system(size: 16))
                        Text(deviceName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(colors.textPrimary)
                    }
                    Text("⏱ 已用 \(elapsedText)")
                        .font(.system(size: 15))
                        .foregroundStyle(colors.textSecondary)

                    if loading {
                        HStack(spacing: 6) {
                            ProgressView().tint(colors.accent).scaleEffect(0.8)
                            Text("结算中...")
                                .font(.system(size: 14))
                                .foregroundStyle(colors.textSecondary)
                        }
                        .padding(.top, 6)
                    } else {
                        // 金额可能是 nil（还没结算出来）——那是「还不知道」，
                        // 不能显示成 ¥0.00，否则用户以为没花钱
                        Text(consumed.map { "本次消费：\(MoneyFormat.withSymbol($0))" }
                             ?? "消费金额稍后可在账单中查看")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(colors.accent)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity)
            } actions: {
                DialogFilledButton(title: "确 认", color: colors.accent, action: onConfirm)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - 动钱前的二次确认（对照 DeductConfirmDialog）

struct DeductConfirmDialogView: View {
    @Environment(\.appColors) private var colors
    /// null = 金额未知，不能按 0 算
    let amount: Double?
    let detail: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        DialogScrim(onTapOutside: onDismiss) {
            AlertCard(title: "确认补扣", titleAlign: .leading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(amount.map { MoneyFormat.withSymbol($0) } ?? "金额未知")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(colors.textPrimary)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                    Text("将从你的校园卡账户扣款，扣款后不可撤销。")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.warning)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } actions: {
                DialogTextButton(title: "取消", color: colors.accent, action: onDismiss)
                DialogFilledButton(title: "确认扣款", color: colors.warning, action: onConfirm)
            }
        }
    }
}

// MARK: - 通用确认（退出登录等）

struct ConfirmDialogView: View {
    @Environment(\.appColors) private var colors
    let title: String
    let message: String
    let confirmTitle: String
    var destructive: Bool = false
    /// 取消键文案。传 nil 表示**不显示取消键**
    /// （对照 Android：只有能退出时才给 dismissButton「取消」）
    var cancelTitle: String? = "取消"
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        DialogScrim(onTapOutside: onDismiss) {
            AlertCard(title: title, titleAlign: .center) {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } actions: {
                if let cancelTitle {
                    DialogTextButton(title: cancelTitle, color: colors.accent, action: onDismiss)
                }
                DialogTextButton(
                    title: confirmTitle,
                    color: destructive ? colors.danger : colors.accent,
                    action: onConfirm
                )
            }
        }
    }
}
