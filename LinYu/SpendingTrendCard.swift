import SwiftUI

/// 消费趋势卡 —— 逐条对照 Android 的 `SpendingTrendCard.kt`。
///
/// 四个状态（时间范围 / 图表类型 / 折叠 / 选中点）**跨会话保留**：
/// Android 那边原来用 `remember` 存在 Composable 里，退出「我的」再进来就复位，
/// 用户每次都得重新点一遍。这里初始化从 `Prefs` 读、变化时写回。
struct SpendingTrendCard: View {
    let bills: [BillDTO]
    let loading: Bool

    @Environment(\.appColors) private var colors

    enum ChartType: String {
        case bar = "BAR"
        case line = "LINE"
    }

    @State private var range: SpendingAnalytics.Range
    @State private var chartType: ChartType
    @State private var collapsed: Bool
    @State private var selectedIndex: Int?

    init(bills: [BillDTO], loading: Bool) {
        self.bills = bills
        self.loading = loading
        _range = State(initialValue: SpendingAnalytics.Range(rawValue: Prefs.trendRange) ?? .last7)
        _chartType = State(initialValue: ChartType(rawValue: Prefs.trendChartType) ?? .line)
        _collapsed = State(initialValue: Prefs.trendCollapsed)
    }

    private var summary: SpendingAnalytics.Summary {
        SpendingAnalytics.summarize(bills: bills, range: range)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("消费趋势")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
                Spacer()
                Button {
                    collapsed.toggle()
                    Prefs.trendCollapsed = collapsed
                } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel(collapsed ? "展开消费趋势" : "折叠消费趋势")
            }

            if !collapsed {
                let s = summary

                HStack(alignment: .top, spacing: 0) {
                    metric("总消费", MoneyFormat.withSymbol(s.total))
                    metric("消费次数", "\(s.count) 次")
                    metric("单次平均", MoneyFormat.withSymbol(s.average))
                }
                .padding(.top, 18)

                if loading {
                    HStack {
                        Spacer()
                        ProgressView().tint(colors.accent)
                        Spacer()
                    }
                    .frame(height: 190)
                } else {
                    // 选中项说明 + 两个分段控件
                    HStack(spacing: 0) {
                        Text(selectedText(s))
                            .font(.system(size: 12, weight: selectedIndex == nil ? .regular : .medium))
                            .foregroundStyle(selectedIndex == nil ? colors.textSecondary : colors.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        segmented(
                            items: SpendingAnalytics.Range.allCases.map { ($0.rawValue, $0.label) },
                            selected: range.rawValue
                        ) { key in
                            if let r = SpendingAnalytics.Range(rawValue: key) {
                                range = r
                                Prefs.trendRange = r.rawValue
                                selectedIndex = nil
                            }
                        }
                        .frame(maxWidth: .infinity)

                        segmented(
                            items: [("BAR", "柱形"), ("LINE", "折线")],
                            selected: chartType.rawValue
                        ) { key in
                            if let t = ChartType(rawValue: key) {
                                chartType = t
                                Prefs.trendChartType = t.rawValue
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.leading, 4)
                    }
                    .frame(height: 32)
                    .padding(.top, 18)

                    TrendChartView(
                        points: s.points,
                        isBar: chartType == .bar,
                        selectedIndex: selectedIndex,
                        accent: colors.accent,
                        pointFill: colors.card
                    ) { idx in
                        selectedIndex = idx
                    }
                    .frame(height: 146)

                    // 横轴标签
                    HStack {
                        ForEach(Array(TrendDisplayPolicy.axisIndices(size: s.points.count).enumerated()), id: \.offset) { _, idx in
                            Text(shortDate(s.points[idx].date))
                                .font(.system(size: 10))
                                .foregroundStyle(colors.textSecondary)
                            if idx != TrendDisplayPolicy.axisIndices(size: s.points.count).last {
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .linyuCard(colors, radius: 18)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(colors.textSecondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectedText(_ s: SpendingAnalytics.Summary) -> String {
        guard let i = selectedIndex, i >= 0, i < s.points.count else { return "每日明细" }
        let p = s.points[i]
        return "\(shortDate(p.date))  \(MoneyFormat.withSymbol(p.amount)) · \(p.count)次"
    }

    /// 两三个小胶囊组成的分段控件（对照 `TrendRangeControl` / `TrendChartTypeControl`）
    private func segmented(
        items: [(key: String, label: String)],
        selected: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.key) { item in
                let active = item.key == selected
                Button { onSelect(item.key) } label: {
                    Text(item.label)
                        .font(.system(size: 11, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? colors.accent : colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(active ? colors.accent.opacity(0.14) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .frame(height: 30)
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d"
        return f.string(from: d)
    }
}

/// 折线图 / 柱状图（Canvas 手绘，对照 Android 的 `TrendChart`）
private struct TrendChartView: View {
    let points: [SpendingAnalytics.DailySpend]
    let isBar: Bool
    let selectedIndex: Int?
    let accent: Color
    let pointFill: Color
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !points.isEmpty else { return }

                let topInset: CGFloat = 10
                let bottomInset: CGFloat = 10
                let bottom = size.height - bottomInset
                let usable = bottom - topInset
                let maxAmount = max(points.map(\.amount).max() ?? 1, 1)

                let barWidth = size.width / CGFloat(points.count) * 0.58
                let inset = isBar ? max(barWidth / 2, 5) : 5

                func position(_ i: Int) -> CGPoint {
                    let ratio = CGFloat(points[i].amount / maxAmount)
                    return CGPoint(
                        x: TrendDisplayPolicy.plotX(
                            index: i, size: points.count, width: size.width, horizontalInset: inset
                        ),
                        y: bottom - usable * ratio
                    )
                }

                if isBar {
                    for i in points.indices {
                        let p = position(i)
                        let rect = CGRect(
                            x: p.x - barWidth / 2,
                            y: p.y,
                            width: barWidth,
                            height: bottom - p.y
                        )
                        ctx.fill(
                            Path(roundedRect: rect, cornerRadius: 4),
                            with: .color(accent.opacity(0.72))
                        )
                    }
                } else {
                    var line = Path()
                    for i in points.indices {
                        let p = position(i)
                        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                    }
                    var area = Path()
                    area.move(to: CGPoint(x: 0, y: bottom))
                    for i in points.indices { area.addLine(to: position(i)) }
                    area.addLine(to: CGPoint(x: size.width, y: bottom))
                    area.closeSubpath()

                    ctx.fill(area, with: .color(accent.opacity(0.10)))
                    ctx.stroke(line, with: .color(accent), lineWidth: 2.5)
                }

                // 每个数据点画一个小圆点（选中的更大）
                for i in points.indices {
                    let p = position(i)
                    let selected = i == selectedIndex
                    let r: CGFloat = selected ? 5 : 3
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                        with: .color(accent)
                    )
                    let ri: CGFloat = selected ? 2 : 1
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: p.x - ri, y: p.y - ri, width: ri * 2, height: ri * 2)),
                        with: .color(pointFill)
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { v in
                        guard !points.isEmpty else { return }
                        let idx: Int
                        if points.count == 1 {
                            idx = 0
                        } else {
                            // 命中区域使用与绘制一致的边距，月视图首尾点也能准确选中。
                            let barWidth = geo.size.width / CGFloat(points.count) * 0.58
                            let inset = isBar ? max(barWidth / 2, 5) : 5
                            let ratio = (v.location.x - inset) / max(geo.size.width - 2 * inset, 1)
                            idx = Int((ratio * CGFloat(points.count - 1)).rounded())
                        }
                        onSelect(min(max(idx, 0), points.count - 1))
                    }
            )
        }
    }
}
