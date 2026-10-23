import SwiftUI

/// 设计系统 —— 逐值对照 Android 的 `ui/theme/Theme.kt`。
///
/// ## 液态玻璃风格
///
/// 卡片是**半透明**的（浅色 72% 透白、深色 75% 磨砂），配一条极淡描边。
/// 所以卡片不能给阴影——半透明叠在渐变背景上时阴影会显脏，Android 注释里也写了这点。
struct AppColorSet {
    let background: Color
    let card: Color
    let solidSurface: Color
    let primary: Color
    var accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let success: Color
    let warning: Color
    let danger: Color
    let activeBg: Color
    let surfaceVariant: Color
    let border: Color
    let isDark: Bool

    /// 浅色：`#F1F5F9` / 72% 透白卡片 / 强调 `#2563EB`
    static let light = AppColorSet(
        background: Color(hex: 0xF1F5F9),
        card: Color(hex: 0xFFFFFF, alpha: 0xB8 / 255.0),
        solidSurface: Color(hex: 0xFFFFFF),
        primary: Color(hex: 0x0D1117),
        accent: Color(hex: 0x2563EB),
        textPrimary: Color(hex: 0x111827),
        textSecondary: Color(hex: 0x6B7280),
        success: Color(hex: 0x22C55E),
        warning: Color(hex: 0xF59E0B),
        danger: Color(hex: 0xEF4444),
        activeBg: Color(hex: 0xFFF7ED),
        surfaceVariant: Color(hex: 0xF0F0F0),
        border: Color(hex: 0x000000, alpha: 0x14 / 255.0),
        isDark: false
    )

    /// 深色：`#0E131D` / 75% 磨砂 `#1D232E` / 强调 `#58A6FF`
    static let dark = AppColorSet(
        background: Color(hex: 0x0E131D),
        card: Color(hex: 0x1D232E, alpha: 0xBF / 255.0),
        solidSurface: Color(hex: 0x161B22),
        primary: Color(hex: 0xE6EDF3),
        accent: Color(hex: 0x58A6FF),
        textPrimary: Color(hex: 0xE6EDF3),
        textSecondary: Color(hex: 0x8B949E),
        success: Color(hex: 0x3FB950),
        warning: Color(hex: 0xD29922),
        danger: Color(hex: 0xF85149),
        activeBg: Color(hex: 0x1B1F23),
        surfaceVariant: Color(hex: 0x21262D),
        border: Color(hex: 0xFFFFFF, alpha: 0x14 / 255.0),
        isDark: true
    )

    /// 选中滑块上的文字色：按强调色**亮度**挑黑或白。
    ///
    /// Android 注释里踩过：滑块颜色可能来自自定义背景提取，写死深蓝/白都可能糊成一片。
    var onAccent: Color {
        let (r, g, b) = accent.rgb
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.5 ? Color(hex: 0x0F172A) : .white
    }
}

// MARK: - 环境注入

private struct AppColorsKey: EnvironmentKey {
    static let defaultValue = AppColorSet.light
}

extension EnvironmentValues {
    var appColors: AppColorSet {
        get { self[AppColorsKey.self] }
        set { self[AppColorsKey.self] = newValue }
    }
}

private struct ThemeModeKey: EnvironmentKey {
    static let defaultValue = false   // false = light
}

extension EnvironmentValues {
    var isDarkMode: Bool {
        get { self[ThemeModeKey.self] }
        set { self[ThemeModeKey.self] = newValue }
    }
}

// MARK: - Color 工具

extension Color {
    /// `Color(hex: 0x2563EB)`
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }

    /// 取 RGB 分量（用于亮度计算）
    var rgb: (Double, Double, Double) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
        #else
        return (0, 0, 0)
        #endif
    }
}

// MARK: - 常用修饰

extension View {
    /// 液态玻璃卡片：22dp 圆角 + 半透明底 + 0.8dp 淡描边，**无阴影**
    func linyuCard(_ colors: AppColorSet, radius: CGFloat = 22) -> some View {
        self
            .background(colors.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(colors.border, lineWidth: 0.8)
            )
    }

    /// 圆形图标按钮的底（40dp）
    func circleIconBackground(_ colors: AppColorSet) -> some View {
        self
            .frame(width: 40, height: 40)
            .background(colors.card)
            .clipShape(Circle())
    }
}
