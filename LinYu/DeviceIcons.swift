import SwiftUI

/// 一个 Android VectorDrawable 图标（只支持 fill + group 的 scale/translate，够用即可）
struct VectorIcon {
    /// 父 group 的缩放
    var scale: CGFloat = 1
    /// 父 group 的平移（viewport 单位）
    var translate: CGPoint = .zero
    /// 每条 path 的数据；`translate` 是**子 group** 的平移（嵌套 group 才需要）
    var paths: [(d: String, translate: CGPoint)]

    init(scale: CGFloat = 1, translate: CGPoint = .zero, paths: [String]) {
        self.scale = scale
        self.translate = translate
        self.paths = paths.map { ($0, .zero) }
    }

    init(scale: CGFloat, translate: CGPoint, paths: [(String, CGPoint)]) {
        self.scale = scale
        self.translate = translate
        self.paths = paths.map { ($0.0, $0.1) }
    }
}

/// 用 Canvas 把 VectorIcon 画出来，颜色由调用方定（Android 那边是 `tint`）
struct VectorIconView: View {
    let icon: VectorIcon
    var size: CGFloat
    var tint: Color
    var viewport: CGFloat = 24

    var body: some View {
        Canvas { ctx, canvasSize in
            let viewportScale = canvasSize.width / viewport
            ctx.scaleBy(x: viewportScale, y: viewportScale)
            ctx.translateBy(x: icon.translate.x, y: icon.translate.y)
            ctx.scaleBy(x: icon.scale, y: icon.scale)

            for item in icon.paths {
                let p = SVGPathParser.path(from: item.d)
                if item.translate == .zero {
                    ctx.fill(p, with: .color(tint))
                } else {
                    var sub = ctx
                    sub.translateBy(x: item.translate.x, y: item.translate.y)
                    sub.fill(p, with: .color(tint))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// 逐字节照抄 `res/drawable/ic_device_*.xml` 的 pathData。
///
/// ## 为什么不用 SF Symbols
///
/// 这两个图标是项目自己的图形语言（花洒 / 牙刷压在水滴上），
/// SF Symbols 里没有对应形状，硬找近似的会一眼看出「不是同一个 App」。
/// `pathData` 是从 SVG 转来的、和源文件一致，直接画就是原样。
enum DeviceIcons {

    /// `ic_device_shower.xml`（24dp 画布，内容缩放到 20×20）
    static let shower = VectorIcon(
        scale: 0.038865,
        translate: CGPoint(x: 2.3804, y: 3.3051),
        paths: [
            ("M504.7900 171.5740 c-.136-2.87-.248-5.863-.364-8.948c-1.148-30.431-2.721-72.107-29.12-98.508c-27.57-27.57-60.066-39.92-93.985-35.719c-29.462 3.651-58.425 19.247-86.119 46.355C239.99 31.689 166.996 22.42 104.107 46.917c-9.664 3.764-15.216 11.011-16.988 19.364c16.28-6.094 79.699 39.713 146.323 106.337c63.805 63.805 108.51 124.665 106.827 144.001c7.36-2.384 13.624-7.829 17.012-16.526c24.493-62.874 15.238-135.847-27.802-191.053c19.557-19.022 39.499-30.275 57.802-32.543c19.079-2.363 36.66 4.798 53.756 21.892c12.956 12.956 14.114 43.652 14.959 66.065c.115 3.038.227 5.99.357 8.831v145.977c0 13.383 10.85 24.232 24.232 24.232s24.232-10.85 24.232-24.232V172.719z", .zero),
            ("M233.4410 172.6170 c69.986 69.986 117.003 136.438 105.017 148.424c-11.987 11.987-78.439-35.031-148.424-105.017S73.03 79.587 85.017 67.6s78.438 35.031 148.424 105.017", .zero),
            ("M382.4000 155.8190 a141.933 141.933 0 0 0-41.404-92.618a141.934 141.934 0 0 0-92.619-41.405c-12.484-.692-24.16 5.81-30.223 16.549c34.897 7.826 68.064 25.312 95.229 52.477c27.163 27.163 44.647 60.326 52.472 95.219c10.737-6.063 17.238-17.735 16.545-30.222", .zero),
            // 下面三条在子 group 里（translate -30, 30）：出水的水流
            ("M13.3250 272.1960 l96.849-96.849c5.001-5.001 5.001-13.11 0-18.111c-5.001-5.002-13.11-5.002-18.111 0l-96.849 96.849c-5.001 5.001-5.001 13.11 0 18.111c2.5 2.501 5.778 3.751 9.056 3.751s6.555-1.25 9.055-3.751", CGPoint(x: -30, y: 30)),
            ("M141.4970 303.1060 l52.678-52.678c5.001-5.001 5.001-13.11 0-18.111c-5.001-5.002-13.11-5.002-18.111 0l-52.678 52.678c-5.001 5.001-5.001 13.11 0 18.111c2.5 2.501 5.778 3.751 9.056 3.751s6.555-1.25 9.055-3.751", CGPoint(x: -30, y: 30)),
            ("M115.1740 422.5900 l96.849-96.849c5.001-5.001 5.001-13.11 0-18.111c-5.001-5.002-13.11-5.002-18.111 0l-96.849 96.849c-5.001 5.001-5.001 13.11 0 18.111c2.5 2.501 5.778 3.751 9.056 3.751s6.555-1.25 9.055-3.751", CGPoint(x: -30, y: 30)),
        ].map { ($0.0, $0.1) }
    )

    /// `ic_device_sink.xml`（24dp 画布，内容缩放到约 21×21）
    static let sink = VectorIcon(
        scale: 0.714272,
        translate: CGPoint(x: 0.5716, y: 0.5716),
        paths: [
            "M11.0800 3.7400 a1.056 1.056 0 0 1 1.48 0a1.024 1.024 0 0 1 0 1.47L9.35 8.437l-1.107-.553l-.373-.927z",
            "M13.9380 6.5900 a1.056 1.056 0 0 1 1.48 0a1.056 1.056 0 0 1 0 1.48L12.2 11.287l-1.23-.301l-.25-1.178z",
            "M11.1280 2.3100 a1.026 1.026 0 0 0-1.47 0L6.44 5.523l.468.989L7.92 7l3.219-3.213a1.043 1.043 0 0 0-.01-1.477",
            "M13.9800 5.1600 a1.054 1.054 0 0 0-1.477 0L9.29 8.38l.385.956l1.092.52l3.213-3.21a1.047 1.047 0 0 0 0-1.487",
            "M15.3580 8.0200 a1.056 1.056 0 0 1 1.48 0c.414.404.414 1.066.01 1.48l-3.218 3.217l-1.208-.456l-.272-1.023z",
            "M20.7200 17.3240 a12.282 12.282 0 0 0-3.876-2.637a12.28 12.28 0 0 1-3.876-2.636L6.609 5.629a2.086 2.086 0 0 0-2.986 0a2.137 2.137 0 0 0 0 3.016l6.062 6.122l.287.3l13.893 14.042a2.981 2.981 0 0 0 4.252 0a3.053 3.053 0 0 0 0-4.295z",
        ]
    )

    /// `ic_qr_code_scanner.xml`（Material Icons Outlined / qr_code_scanner）
    static let qrScanner = VectorIcon(
        paths: [
            "M9.5,6.5v3h-3v-3H9.5M11,5H5v6h6V5L11,5zM9.5,14.5v3h-3v-3H9.5M11,13H5v6h6V13L11,13zM17.5,6.5v3h-3v-3H17.5M19,5h-6v6h6V5L19,5zM13,13h1.5v1.5H13V13zM14.5,14.5H16V16h-1.5V14.5zM16,13h1.5v1.5H16V13zM13,16h1.5v1.5H13V16zM14.5,17.5H16V19h-1.5V17.5zM16,16h1.5v1.5H16V16zM17.5,14.5H19V16h-1.5V14.5zM17.5,17.5H19V19h-1.5V17.5zM22,7h-2V4h-3V2h5V7zM22,22v-5h-2v3h-3v2H22zM2,22h5v-2H4v-3H2V22zM2,2v5h2V4h3V2H2z",
        ]
    )

    /// emoji → 图标。没有对应图标时返回 nil，调用方回退去画 emoji。
    ///
    /// 数据层仍然是 emoji（`DeviceInfo.typeEmoji` 会进持久化和小组件快照），
    /// 这里只做「渲染时映射」——和 Android 的 `deviceIconRes` 完全一致，
    /// 老数据不需要迁移。
    static func icon(for emoji: String) -> VectorIcon? {
        switch emoji {
        case "🚿": return shower
        case "🪥": return sink
        default: return nil
        }
    }
}
