import Foundation

enum ColorContrastPolicy {
    /// Compose Color.luminance(): 先把 sRGB 转为线性值，再计算相对亮度。
    static func usesDarkForeground(red: Double, green: Double, blue: Double) -> Bool {
        func linear(_ value: Double) -> Double {
            let v = min(1, max(0, value))
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) > 0.5
    }
}
