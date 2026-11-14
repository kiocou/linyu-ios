import SwiftUI

/// 悬浮胶囊底栏 —— 对照 Android 的 `FloatingPillNavBar.kt`。
///
/// - 整体 260pt 宽、28pt 圆角、内部 padding 4pt
/// - 高亮滑块 42pt 高、22pt 圆角，用强调色（会随自定义背景提取的主题色变化）
/// - 弹簧动画 `damping 0.72 / stiffness 380`，产生轻微"果冻"回弹
/// - **无点击水波纹、无按压缩放**，只靠滑块滑动作为反馈
struct PillNavBar: View {
    @Binding var currentTab: Int
    let colors: AppColorSet

    private let barWidth: CGFloat = 260
    private let barHeight: CGFloat = 42
    private let inset: CGFloat = 4

    private let tabs: [(title: String, icon: String)] = [
        ("首页", "house.fill"),
        ("账单", "doc.text.fill"),
        ("我的", "person.fill")
    ]

    private var itemWidth: CGFloat { (barWidth - inset * 2) / 3 }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                // 高亮滑块
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(colors.accent)
                    .frame(width: itemWidth, height: barHeight)
                    .offset(x: itemWidth * CGFloat(currentTab))
                    .animation(.interpolatingSpring(stiffness: 380, damping: 28.07), value: currentTab)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)

                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        tabItem(index: index, tab: tab)
                    }
                }
            }
            .padding(inset)
        }
        .frame(width: barWidth)
        .background(
            (colors.isDark ? Color(hex: 0x1A202C, alpha: 0xB8 / 255.0)
                           : Color(hex: 0xFFFFFF, alpha: 0xD8 / 255.0))
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    colors.isDark ? Color(hex: 0xFFFFFF, alpha: 0x28 / 255.0)
                                  : Color(hex: 0x000000, alpha: 0x18 / 255.0),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
    }

    private func tabItem(index: Int, tab: (title: String, icon: String)) -> some View {
        let selected = currentTab == index
        let contentColor = selected
            ? colors.onAccent
            : (colors.isDark ? Color(hex: 0x94A3B8) : Color(hex: 0x64748B))

        return Button {
            if currentTab != index {
                // 触觉反馈（对应 Android 的 performHapticFeedback）
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
                currentTab = index
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16))
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(contentColor)
            .frame(width: itemWidth, height: barHeight)
            .scaleEffect(selected ? 1.04 : 1.0)
            .animation(.interpolatingSpring(stiffness: 400, damping: 28.8), value: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
