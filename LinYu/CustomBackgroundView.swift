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
            if let image = images[scope] { accents[scope] = Self.averageColor(image) }
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
    func colors(_ base: AppColorSet, scope: BackgroundScope) -> AppColorSet {
        guard let color = accents[scope] else { return base }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        var result = base
        result.accent = Color(uiColor: UIColor(hue: hue, saturation: max(0.45, saturation), brightness: base.isDark ? 0.9 : 0.65, alpha: 1))
        return result
    }
    private static func averageColor(_ image: UIImage) -> UIColor? {
        guard let input = CIImage(image: image), let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
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
        accents[scope] = Self.averageColor(resized)
        images[scope] = resized
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

struct CustomBackgroundView: View {
    let onBack: () -> Void
    @Environment(\.appColors) private var colors
    @ObservedObject private var backgrounds = BackgroundStore.shared
    @State private var scope: BackgroundScope = .home
    @State private var selection: PhotosPickerItem?
    @State private var loading = false
    @State private var resetConfirm = false
    @State private var errorText: String?
    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Button(action: onBack) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 20))
                                .frame(width: 48, height: 48)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("返回")
                        .disabled(loading)
                        Text("自定义背景").font(.system(size: 20, weight: .bold))
                    }
                    .foregroundStyle(colors.textPrimary)
                    .padding(.bottom, 12)
                    HStack(spacing: 10) {
                        scopeChip("主页", value: .home)
                        scopeChip("使用页", value: .shower)
                    }
                    .disabled(loading)
                    Text(scope == .home ? "应用于：首页 / 账单 / 我的" : "应用于：洗澡中的使用页")
                        .font(.system(size: 12)).foregroundStyle(colors.textSecondary)
                        .padding(.top, 6).padding(.bottom, 14)
                    preview
                        .padding(.bottom, 16)
                    PhotosPicker(selection: $selection, matching: .images) {
                        Text(backgrounds.image(scope) == nil ? "选择背景图片" : "更换背景图片")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(colors.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain).disabled(loading)
                    if backgrounds.image(scope) != nil {
                        HStack(spacing: 0) {
                            Text("主题色").font(.system(size: 13))
                            Circle().fill(backgrounds.themeColor(scope) ?? colors.accent)
                                .frame(width: 20, height: 20).padding(.leading, 10).padding(.trailing, 8)
                                .accessibilityLabel("图片主题色")
                            Text(backgrounds.themeColor(scope) == nil ? "使用默认强调色" : "已根据图片自动提取")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(colors.textSecondary)
                        .padding(.top, 20).padding(.bottom, 8)
                        adjustment("透明度", keyPath: \.opacity, range: 0.2...1, percentage: true)
                        adjustment("模糊度", keyPath: \.blur, range: 0...20, percentage: false)
                        adjustment("亮度", keyPath: \.brightness, range: 0.4...1.5, percentage: true)
                    }
                    Button { resetConfirm = true } label: {
                        Text("恢复默认背景（仅当前页面）")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(colors.danger)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(colors.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain).disabled(loading).padding(.top, 24)
                    if loading { ProgressView() }
                    if let errorText { Text(errorText).foregroundStyle(.red) }
                }.padding(20).padding(.bottom, 60)
            }
            .background(colors.solidSurface.ignoresSafeArea())
            .ignoresSafeArea(.container, edges: .bottom)
            .alert("恢复默认背景？", isPresented: $resetConfirm) {
                Button("取消", role: .cancel) {}
                Button("恢复默认", role: .destructive) {
                    do { try backgrounds.reset(scope) } catch { errorText = error.localizedDescription }
                }
            } message: { Text("这将移除当前页面的自定义背景及相关效果。\n不会影响深色 / 浅色模式。") }
        .onChange(of: selection) { item in
            guard let item else { return }
            let destination = scope
            loading = true
            errorText = nil
            Task {
                defer { loading = false; selection = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                    try backgrounds.save(data, scope: destination)
                } catch { errorText = "图片加载失败：\(error.localizedDescription)" }
            }
        }
    }
    private func scopeChip(_ title: String, value: BackgroundScope) -> some View {
        Button { scope = value } label: {
            Text(title).font(.system(size: 14, weight: .medium))
                .foregroundStyle(scope == value ? Color.white : colors.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(scope == value ? colors.accent : colors.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(colors.border, lineWidth: 0.8))
        }.buttonStyle(.plain)
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
