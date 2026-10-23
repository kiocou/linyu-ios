import SwiftUI

/// 用水页 —— 逐条对照 Android 的 `ShowerScreen.kt`。
///
/// 布局是**垂直居中**的一列：图标 → 状态 → 位置 → 预扣卡片 → 计时 → 结束按钮。
/// 背景是纵向渐变（浅色冷蓝 `E3F2FD→90CAF9`、深色靛蓝 `1A237E→3949AB`），不是纯色。
///
/// ⚠️ 左下角那行「费率 0.041元/升」是硬编码的说明文字，Android 也是写死的
/// （服务端费率不在本地，写死的是**这个项目的默认费率**，仅作参考）。
struct ShowerScreenView: View {
    let emoji: String
    let statusText: String
    let location: String
    let remaining: String
    let elapsedSec: Int
    let autoDisConSec: Int
    let isStopping: Bool
    let onStop: () -> Void
    let onMinimize: () -> Void

    @Environment(\.appColors) private var colors
    @Environment(\.isDarkMode) private var isDark
    @ObservedObject private var backgrounds = BackgroundStore.shared

    private var timeText: String {
        let m = elapsedSec / 60
        let s = elapsedSec % 60
        return m > 0 ? "\(m)分\(s)秒" : "\(s)秒"
    }

    private var countdownText: String {
        let m = autoDisConSec / 60
        let s = autoDisConSec % 60
        return m > 0 ? "\(m)分\(s)秒" : "\(s)秒"
    }

    private var backgroundGradient: LinearGradient {
        let stops: [Color] = isDark
            ? [Color(hex: 0x1A237E), Color(hex: 0x283593), Color(hex: 0x3949AB)]
            : [Color(hex: 0xE3F2FD), Color(hex: 0xBBDEFB), Color(hex: 0x90CAF9)]
        return LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundGradient.ignoresSafeArea()
            if backgrounds.image(.shower) != nil { AppBackground(scope: .shower) }

            ScrollView {
                VStack(spacing: 0) {
                    // 72pt 图标（和 Android 的 `DeviceGlyph(emoji, 72.sp, 72.dp)` 同尺寸）
                    if backgrounds.image(.shower) == nil {
                        PlainGlyph(emoji: emoji, size: 72, tint: .white)
                            .padding(.bottom, 8)
                    }

                    Text(statusText)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(colors.accent)

                    Text(location)
                        .font(.system(size: 16))
                        .foregroundStyle(colors.textSecondary)
                        .padding(.top, 4)

                    // 预扣金额卡片
                    VStack(spacing: 4) {
                        Text("💧 已预扣 ¥\(remaining)")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(colors.accent)
                        Text("计费以热水器显示为准")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(colors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(isDark ? 0.18 : 0.6), lineWidth: 1)
                    )
                    .padding(.top, 32)

                    // 计时器
                    HStack(spacing: 8) {
                        Text("⏱").font(.system(size: 18))
                        Text("已用 \(timeText)")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(colors.textPrimary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(colors.card.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 24)

                    // 自动关停倒计时
                    if autoDisConSec > 0 {
                        HStack(spacing: 8) {
                            Text("⏳").font(.system(size: 18))
                            Text("闲置约 \(countdownText) 后自动关闭")
                                .font(.system(size: 13))
                                .foregroundStyle(colors.warning)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(colors.warning.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 12)
                    }

                    // 结束按钮
                    Button(action: onStop) {
                        HStack(spacing: 8) {
                            if isStopping {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.9)
                                Text("正在关闭...")
                                    .font(.system(size: 18, weight: .bold))
                                    .tracking(4)
                                    .foregroundStyle(.white)
                            } else {
                                Text("结 束 使 用")
                                    .font(.system(size: 18, weight: .bold))
                                    .tracking(4)
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color(hex: 0xE53935).opacity(isStopping ? 0.4 : 1))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isStopping)
                    .shadow(color: Color(hex: 0xE53935).opacity(0.25), radius: 4, y: 2)
                    .padding(.top, 48)

                    Text("费率: 0.041元/升 · 设备: \(String(location.suffix(6)))")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 640)
                .padding(.top, 40)
            }
            .clipped()

            // 左上角返回（不结束用水）
            Button(action: onMinimize) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回（不结束用水）")
            .padding(.leading, 8)
            .padding(.top, 8)
        }
    }
}
