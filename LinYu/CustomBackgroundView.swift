import SwiftUI
import PhotosUI
import Combine
import CoreImage

enum BackgroundScope: String, CaseIterable { case home, shower }

struct BackgroundOptions: Codable {
    var opacity = 0.7
    var blur = 0.0
    var brightness = 1.0
}

@MainActor
final class BackgroundStore: ObservableObject {
    static let shared = BackgroundStore()
    @Published private var images: [BackgroundScope: UIImage] = [:]
    @Published private var options: [BackgroundScope: BackgroundOptions] = [:]
    private var accents: [BackgroundScope: UIColor] = [:]
    private init() {
        for scope in BackgroundScope.allCases {
            images[scope] = UIImage(contentsOfFile: Self.url(scope).path)
            if let image = images[scope] { accents[scope] = Self.extractThemeColor(image) }
            if let data = UserDefaults.standard.data(forKey: "background.\(scope.rawValue)"),
               let value = try? JSONDecoder().decode(BackgroundOptions.self, from: data) { options[scope] = value }
        }
    }
    private static func url(_ scope: BackgroundScope) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("background-\(scope.rawValue).jpg")
    }
    func image(_ scope: BackgroundScope) -> UIImage? { images[scope] }
    func themeColor(_ scope: BackgroundScope) -> Color? { accents[scope].map { Color(uiColor: $0) } }
    /// 强调色覆盖 —— 对照 Android `LinYuThemeSpecific`：
    ///
    /// ```
    /// val bgTheme = BackgroundState.config(SCOPE_HOME).themeColor
    /// val set = if (bgTheme != null) base.copy(Accent = Color(bgTheme)) else base
    /// ```
    ///
    /// ⚠️ 两个细节别改：
    /// - 只认 **home** 作用域（使用页的背景色不影响全局强调色）
    /// - 提取出来是什么色就**原样**用，不再二次调饱和度/亮度（那是另一套颜色了）
    func colors(_ base: AppColorSet) -> AppColorSet {
        guard let color = accents[.home] else { return base }
        var result = base
        result.accent = Color(uiColor: color)
        return result
    }
    /// 从背景图提取「UI 可用的主题色」—— 逐行对照 Android `BackgroundManager.extractThemeColor`。
    ///
    /// 做法：
    /// 1. 缩到 **48×48**
    /// 2. 每个通道按 **32 一档**量化后统计出现次数（相当于简易调色板）
    /// 3. 过滤掉过暗(V≤0.20)、过亮(V≥0.95)、过灰(S≤0.15)的颜色
    /// 4. 取**占比最高**的那一档
    /// 5. 把饱和度夹到 0.35~0.75、亮度夹到 0.45~0.85
    ///
    /// ⚠️ 以前这里用 `CIAreaAverage` 取平均色 —— 那是**所有像素的平均**，
    /// 结果几乎总是灰白/土色，跟图上看着最显眼的颜色对不上，
    /// 所以界面上显示的主题色和用户预期的完全不是一回事。
    private static func extractThemeColor(_ image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }

        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &pixels,
                width: side, height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        // ① 量化统计
        var counts: [Int: Int] = [:]
        counts.reserveCapacity(256)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = (Int(pixels[i]) / 32) * 32
            let g = (Int(pixels[i + 1]) / 32) * 32
            let b = (Int(pixels[i + 2]) / 32) * 32
            let key = (r << 16) | (g << 8) | b
            counts[key, default: 0] += 1
        }

        // ② 过滤 + 取占比最高
        var best: (key: Int, count: Int)?
        for (key, count) in counts {
            let color = UIColor(
                red: CGFloat((key >> 16) & 0xFF) / 255.0,
                green: CGFloat((key >> 8) & 0xFF) / 255.0,
                blue: CGFloat(key & 0xFF) / 255.0,
                alpha: 1
            )
            var h: CGFloat = 0, sat: CGFloat = 0, val: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &sat, brightness: &val, alpha: &a)
            guard sat > 0.15, val > 0.20, val < 0.95 else { continue }
            if best == nil || count > best!.count { best = (key, count) }
        }
        guard let picked = best?.key else { return nil }

        // ③ 夹到「适合 UI」的饱和度 / 亮度
        var h: CGFloat = 0, sat: CGFloat = 0, val: CGFloat = 0, a: CGFloat = 0
        UIColor(
            red: CGFloat((picked >> 16) & 0xFF) / 255.0,
            green: CGFloat((picked >> 8) & 0xFF) / 255.0,
            blue: CGFloat(picked & 0xFF) / 255.0,
            alpha: 1
        ).getHue(&h, saturation: &sat, brightness: &val, alpha: &a)

        return UIColor(
            hue: h,
            saturation: min(max(sat, 0.35), 0.75),
            brightness: min(max(val, 0.45), 0.85),
            alpha: 1
        )
    }

    func settings(_ scope: BackgroundScope) -> BackgroundOptions { options[scope] ?? BackgroundOptions() }
    func update(_ scope: BackgroundScope, _ value: BackgroundOptions) {
        options[scope] = value
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "background.\(scope.rawValue)") }
    }
    func save(_ data: Data, scope: BackgroundScope) throws {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let ratio = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
        let url = Self.url(scope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        accents[scope] = Self.extractThemeColor(resized)
        images[scope] = resized
        // 换图后把三个效果参数复位成默认值。
        // 对照 Android：否则会沿用上一张图调过的参数，新图看着「莫名其妙变暗/变糊」。
        update(scope, BackgroundOptions())
    }
    func reset(_ scope: BackgroundScope) throws {
        let url = Self.url(scope)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        accents[scope] = nil
        images[scope] = nil
        update(scope, BackgroundOptions())
    }
}

struct AppBackground: View {
    @Environment(\.appColors) private var colors
    @ObservedObject private var backgrounds = BackgroundStore.shared
    var scope: BackgroundScope = .home
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                colors.background
                if let image = backgrounds.image(scope) {
                    let settings = backgrounds.settings(scope)
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .brightness(settings.brightness - 1).blur(radius: settings.blur)
                        .opacity(settings.opacity)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

/// 自定义背景设置页（全屏）—— 逐条对照 Android 的 `CustomBackgroundScreen.kt`。
///
/// 结构（自上而下，与 Kotlin 版一致）：
/// ```
/// [←]  自定义背景
/// [ 主页 ][ 使用页 ]
/// 应用于：首页 / 账单 / 我的
/// ┌ 预览（200pt）─────────────┐
/// │ [示例卡片]                │
/// └──────────────────────────┘
/// [ 选择背景图片 / 更换背景图片 ]
/// 主题色 ●  已根据图片自动提取
/// 透明度 ————————○———  70%
/// 模糊度 ————————○———  0
/// 亮度   ————————○———  100%
/// [ 恢复默认背景（仅当前页面） ]
/// ```
///
/// ⚠️ 不包含任何深色/浅色模式控件，与主题切换完全解耦（Android 注释也强调了这点）。
struct CustomBackgroundView: View {
    let onBack: () -> Void
    @Environment(\.appColors) private var colors
    @ObservedObject private var backgrounds = BackgroundStore.shared
    /// 上次看的是哪一套（主页 / 使用页）—— 对照 Android `PrefsHelper.backgroundScope`
    @State private var scope: BackgroundScope = BackgroundScope(rawValue: Prefs.backgroundScope) ?? .home
    @State private var selection: PhotosPickerItem?
    @State private var loading = false
    /// 恢复默认的确认弹窗 —— 用应用内居中卡片，**不用系统 `.alert`**
    /// （Android 用的是 Material3 `AlertDialog`，样式与这里一致）
    @State private var resetConfirm = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            colors.solidSurface.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 顶栏：IconButton(ArrowBack) + 标题
                    HStack(spacing: 0) {
                        Button(action: onBack) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 20))
                                .foregroundStyle(colors.textPrimary)
                                .frame(width: 48, height: 48)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("返回")

                        Text("自定义背景")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(colors.textPrimary)
                    }
                    .padding(.bottom, 12)

                    // 页面切换：主页 / 使用页（两套独立背景）
                    HStack(spacing: 10) {
                        scopeChip("主页", value: .home)
                        scopeChip("使用页", value: .shower)
                    }
                    .onChange(of: scope) { Prefs.backgroundScope = $0.rawValue }

                    Text(scope == .home ? "应用于：首页 / 账单 / 我的" : "应用于：洗澡中的使用页")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                        .padding(.top, 6)
                        .padding(.bottom, 14)

                    preview
                        .padding(.bottom, 16)

                    // 选择 / 更换图片（存到当前选中的那套）
                    PhotosPicker(selection: $selection, matching: .images) {
                        Text(backgrounds.image(scope) == nil ? "选择背景图片" : "更换背景图片")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(colors.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(loading)

                    // 效果调节（有背景时才显示）
                    if backgrounds.image(scope) != nil {
                        // 自动提取的主题色
                        HStack(spacing: 0) {
                            Text("主题色")
                                .font(.system(size: 13))
                                .foregroundStyle(colors.textSecondary)
                            Circle()
                                .fill(backgrounds.themeColor(scope) ?? colors.accent)
                                .frame(width: 20, height: 20)
                                .padding(.leading, 10)
                                .padding(.trailing, 8)
                                .accessibilityLabel("图片主题色")
                            Text(backgrounds.themeColor(scope) == nil ? "使用默认强调色" : "已根据图片自动提取")
                                .font(.system(size: 12))
                                .foregroundStyle(colors.textSecondary)
                        }
                        .padding(.top, 20)
                        .padding(.bottom, 8)

                        adjustment("透明度", keyPath: \.opacity, range: 0.2 ... 1, percentage: true)
                        adjustment("模糊度", keyPath: \.blur, range: 0 ... 20, percentage: false)
                        adjustment("亮度", keyPath: \.brightness, range: 0.4 ... 1.5, percentage: true)
                    }

                    // 恢复默认（OutlinedButton）
                    Button { resetConfirm = true } label: {
                        Text("恢复默认背景（仅当前页面）")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(colors.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(colors.danger.opacity(0.5), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(loading)
                    .padding(.top, 24)

                    if loading { ProgressView().padding(.top, 12) }
                    if let errorText {
                        Text(errorText).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 8)
                    }

                    // Android: Spacer(60.dp)
                    Color.clear.frame(height: 60)
                }
                .padding(20)
            }
            // 安卓 `verticalScroll` 不显示滚动条
            .scrollIndicators(.hidden)

            // 恢复默认确认（对照 Android 的 Material3 AlertDialog）
            if resetConfirm {
                DialogScrim(onTapOutside: { resetConfirm = false }) {
                    AlertCard(title: "恢复默认背景？", titleAlign: .leading) {
                        Text("这将移除当前页面的自定义背景及相关效果。\n不会影响深色 / 浅色模式。")
                            .font(.system(size: 14))
                            .foregroundStyle(colors.textSecondary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } actions: {
                        DialogTextButton(title: "取消", color: colors.accent) { resetConfirm = false }
                        DialogFilledButton(title: "恢复默认", color: colors.danger) {
                            resetConfirm = false
                            do { try backgrounds.reset(scope) } catch { errorText = error.localizedDescription }
                        }
                    }
                }
            }
        }
        // 安卓 `BackHandler(onBack = onDismiss)` 的等价物：左边缘右滑返回
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard value.startLocation.x < 30,
                      value.translation.width > 80,
                      abs(value.translation.height) < 60 else { return }
                onBack()
            }
        )
        .onChange(of: selection) { item in
            guard let item else { return }
            let destination = scope
            loading = true
            errorText = nil
            Task {
                defer { loading = false; selection = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try backgrounds.save(data, scope: destination)
                } catch {
                    errorText = "图片加载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 主页 / 使用页 切换 —— 对照 Android `ScopeChip`（Surface(onClick)）
    private func scopeChip(_ title: String, value: BackgroundScope) -> some View {
        Button { scope = value } label: {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(scope == value ? Color.white : colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(scope == value ? colors.accent : colors.card,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(colors.border, lineWidth: 0.8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scope == value ? .isSelected : [])
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                colors.background
                if let image = backgrounds.image(scope) {
                    let settings = backgrounds.settings(scope)
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .brightness(settings.brightness - 1).blur(radius: settings.blur)
                        .opacity(settings.opacity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("示例卡片").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(colors.textPrimary)
                        Text("文字在背景上的可读性效果").font(.system(size: 12))
                            .foregroundStyle(colors.textSecondary)
                    }
                    .padding(14)
                    .frame(width: geometry.size.width * 0.7 - 32, alignment: .leading)
                    .background(colors.card, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(colors.border, lineWidth: 0.8))
                } else {
                    Text("未设置背景").foregroundStyle(colors.textSecondary)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 18))
        // 裁剪只限制绘制；放大的图片仍可能在预览外参与命中测试。
        // 整块预览仅展示，必须让触摸穿过，避免挡住返回和范围切换。
        .allowsHitTesting(false)
    }

    private func adjustment(_ title: String, keyPath: WritableKeyPath<BackgroundOptions, Double>, range: ClosedRange<Double>, percentage: Bool) -> some View {
        let value = backgrounds.settings(scope)[keyPath: keyPath]
        let display = percentage ? String(format: "%.0f%%", value * 100) : String(format: "%.0f", value)
        return VStack(alignment: .leading) {
            HStack {
                Text(title).foregroundStyle(colors.textSecondary)
                Spacer()
                Text(display).foregroundStyle(colors.textPrimary).monospacedDigit()
            }.font(.system(size: 13))
            Slider(value: Binding(get: { backgrounds.settings(scope)[keyPath: keyPath] }, set: { value in
                var options = backgrounds.settings(scope); options[keyPath: keyPath] = value
                backgrounds.update(scope, options)
            }), in: range).tint(colors.accent)
                .accessibilityLabel(title).accessibilityValue(display)
        }.padding(.vertical, 6)
    }
}
