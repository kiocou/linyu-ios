import SwiftUI
import WidgetKit
import AppIntents

enum WidgetSlot: String, AppEnum {
    case one = "1", two = "2", three = "3", four = "4"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "独立设置"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.one: "设置一", .two: "设置二", .three: "设置三", .four: "设置四"]
}
@available(iOS 17.0, *)
struct LinYuWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "淋浴小组件"
    static var description = IntentDescription("不同设置可分别选择设备和页面")
    @Parameter(title: "独立设置", default: .one) var slot: WidgetSlot
}
struct WidgetPageIntent: AppIntent {
    static var title: LocalizedStringResource = "切换小组件页面"
    @Parameter(title: "设置") var slot: String
    @Parameter(title: "页面") var page: Int
    init() {}
    init(slot: String, page: Int) { self.slot = slot; self.page = page }
    func perform() async throws -> some IntentResult {
        var value = WidgetSharedStore.selection(slot)
        value.owner = WidgetSharedStore.read().owner
        value.tab = min(2, max(0, page))
        WidgetSharedStore.select(value, slot: slot)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
struct WidgetPickIntent: AppIntent {
    static var title: LocalizedStringResource = "选用设备"
    @Parameter(title: "设置") var slot: String
    @Parameter(title: "设备") var sn: String
    @Parameter(title: "身份") var token: String
    init() {}
    init(slot: String, sn: String, token: String) { self.slot = slot; self.sn = sn; self.token = token }
    func perform() async throws -> some IntentResult {
        let snapshot = WidgetSharedStore.read()
        guard snapshot.token == token, !snapshot.owner.isEmpty,
              snapshot.devices.contains(where: { $0.id == sn && ($0.selectable || $0.running) }) else { return .result() }
        // 选用只换目标，不申请费率；真正控制前主应用重新查询设备。
        WidgetSharedStore.select(.init(owner: snapshot.owner, device: sn, tab: 0), slot: slot)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
struct LinYuWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var slot: String
    var selection: WidgetSharedStore.Selection
}
@available(iOS 17.0, *)
struct LinYuWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LinYuWidgetEntry { entry("1") }
    func snapshot(for configuration: LinYuWidgetConfiguration, in context: Context) async -> LinYuWidgetEntry { entry(configuration.slot.rawValue) }
    func timeline(for configuration: LinYuWidgetConfiguration, in context: Context) async -> Timeline<LinYuWidgetEntry> {
        let current = entry(configuration.slot.rawValue)
        var entries = [current]
        if current.snapshot.busy {
            var unknown = current
            unknown.date = Date().addingTimeInterval(31)
            entries.append(unknown)
        }
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(900)))
    }
    private func entry(_ slot: String) -> LinYuWidgetEntry {
        .init(date: Date(), snapshot: WidgetSharedStore.read(), slot: slot, selection: WidgetSharedStore.selection(slot))
    }
}

private struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.16), lineWidth: 1))
    }
}
@available(iOS 17.0, *)
struct LinYuWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: LinYuWidgetEntry
    let layout: String
    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var device: WidgetDevice? { snapshot.selected(entry.selection.device) }
    private var staleBusy: Bool { snapshot.busy && entry.date.timeIntervalSince(snapshot.date) > 30 }
    private var stateColor: Color { device?.running == true ? .cyan : device?.occupied == true ? .orange : .green }
    private func url(_ kind: WidgetCommandKind) -> URL { WidgetCommand.url(kind, snapshot: snapshot, device: device) }
    private var action: WidgetCommandKind {
        if staleBusy { return .refresh }
        if snapshot.owner.isEmpty { return .home }
        guard let device else { return .nearby }
        return device.running ? .stop : .start
    }
    private var title: String {
        if snapshot.owner.isEmpty { return "未登录" }
        guard let device else { return "请先选择设备" }
        return layout == "panel" ? String(device.name.split(separator: " ").last ?? Substring(device.name)) : device.name
    }
    var body: some View {
        Group {
            if layout == "tile" { tile }
            else if layout == "panel" { panel }
            else { wide }
        }
        .padding(layout == "tile" ? 12 : 14)
        .foregroundStyle(.white)
        .font(.system(size: 12))
        .buttonStyle(.plain)
        .containerBackground(for: .widget) {
            Color(red: 15/255, green: 23/255, blue: 32/255)
                .overlay(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .widgetURL(url(.home))
        .privacySensitive()
    }
    private var tile: some View {
        Link(destination: url(action)) {
            VStack(spacing: 12) {
                Image(systemName: device?.running == true ? "stop.fill" : "shower.fill").font(.system(size: 42))
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.head)
                Text(snapshot.message ?? (device?.running == true ? "结束用水" : device?.occupied == true ? "占用中" : "开始用水"))
                    .font(.system(size: 11)).lineLimit(2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(stateColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
        }.disabled(snapshot.busy && !staleBusy)
    }
    private var header: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
            if device != nil {
                Text(device?.running == true ? "● 使用中" : device?.occupied == true ? "● 占用中" : "● 空闲")
                    .font(.system(size: 10)).foregroundStyle(stateColor).fixedSize()
            }
        }
    }
    private var readout: some View {
        VStack(spacing: 5) {
            if staleBusy { Text("状态未知，请刷新").multilineTextAlignment(.center) }
            else if let message = snapshot.message { Text(message).multilineTextAlignment(.center).lineLimit(3) }
            else if let device, device.running, device.startedAt > 0 {
                Text(Date(timeIntervalSince1970: Double(device.startedAt) / 1000), style: .timer)
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("预扣 · ¥\(device.preDeduct, specifier: "%.2f")").font(.system(size: 10))
            } else {
                Text("上次消费").foregroundStyle(.white.opacity(0.65))
                Text((device?.lastConsume ?? 0) > 0 ? String(format: "¥ %.2f", device!.lastConsume) : "¥ —")
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).modifier(Glass())
    }
    private var power: some View {
        Link(destination: url(action)) {
            Image(systemName: device?.running == true ? "stop.fill" : "power")
                .font(.system(size: 25, weight: .medium)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(Glass())
        }.disabled(snapshot.busy && !staleBusy).accessibilityLabel(device?.running == true ? "结束用水" : "开始用水")
    }
    private var panel: some View {
        VStack(spacing: 7) {
            header
            Text(device?.detail ?? "点此打开淋浴").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            readout
            power.frame(height: 33)
        }
    }
    private var wide: some View {
        HStack(spacing: 12) {
            VStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Button(intent: WidgetPageIntent(slot: entry.slot, page: index)) {
                        Image(systemName: ["clock", "antenna.radiowaves.left.and.right", "creditcard"][index])
                            .font(.system(size: 20)).frame(width: 34, height: 34)
                            .background(.white.opacity(entry.selection.tab == index ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 10))
                    }.accessibilityLabel(["设备", "附近设备", "账单"][index])
                }
                if family == .systemLarge { Spacer(minLength: 0) }
            }.frame(width: 36)
            Rectangle().fill(.white.opacity(0.16)).frame(width: 1)
            if entry.selection.tab == 1 { nearby }
            else if entry.selection.tab == 2 { bills }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    Text(device?.detail ?? "点按钮选附近设备").foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    HStack(spacing: 10) { readout; power.frame(width: family == .systemLarge ? 80 : 64) }
                    if device?.running == true { Text("设备状态以最近同步为准").font(.system(size: 9)).foregroundStyle(.white.opacity(0.55)) }
                }
            }
        }
    }
    private var nearby: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("附近设备").fontWeight(.semibold)
                Spacer(minLength: 0)
                Link(destination: url(.nearby)) { Image(systemName: "arrow.clockwise") }
            }
            if let date = snapshot.nearbyDate { Text(date, style: .relative).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)) }
            let devices = snapshot.devices.filter { snapshot.nearbyIDs.contains($0.id) && ($0.selectable || $0.running) }
            if devices.isEmpty { Text("未扫描到附近设备").foregroundStyle(.white.opacity(0.6)); Spacer(minLength: 0) }
            ForEach(Array(devices.prefix(family == .systemLarge ? 5 : 2))) { item in
                HStack(spacing: 6) {
                    Text(item.emoji)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1).truncationMode(.head)
                        if let rssi = item.rssi { Text("\(rssi) dBm").font(.system(size: 9)).foregroundStyle(rssi >= -70 ? .green : rssi >= -85 ? .orange : .red) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("选用", intent: WidgetPickIntent(slot: entry.slot, sn: item.id, token: snapshot.token))
                        .font(.system(size: 10)).padding(7).modifier(Glass())
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var bills: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading) { Text(snapshot.balanceTitle).font(.system(size: 10)); Text(snapshot.balance).font(.system(size: 20, weight: .semibold)) }
                Spacer(minLength: 0)
                Link(destination: url(.bills)) { Image(systemName: "chevron.right") }
            }
            if snapshot.bills.isEmpty { Text("在 App 里刷新账单").foregroundStyle(.white.opacity(0.6)) }
            ForEach(Array(snapshot.bills.prefix(family == .systemLarge ? 5 : 2).enumerated()), id: \.offset) { _, bill in
                HStack(spacing: 5) {
                    Text(bill.emoji)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bill.name).lineLimit(1).truncationMode(.head)
                        Text(bill.time).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(bill.money).font(.system(size: 11)).fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
    }
}

@available(iOS 17.0, *)
struct LinYuTileWidget: Widget {
    let kind = "LinYuTile"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LinYuWidgetConfiguration.self, provider: LinYuWidgetProvider()) { LinYuWidgetView(entry: $0, layout: "tile") }
            .configurationDisplayName("淋浴 · 开关").description("对应安卓方形快捷开关，操作在应用内执行")
            .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
@available(iOS 17.0, *)
struct LinYuPanelWidget: Widget {
    let kind = "LinYuPanel"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LinYuWidgetConfiguration.self, provider: LinYuWidgetProvider()) { LinYuWidgetView(entry: $0, layout: "panel") }
            .configurationDisplayName("淋浴 · 设备").description("设备状态、上次消费与用水操作")
            .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
@available(iOS 17.0, *)
struct LinYuWideWidget: Widget {
    let kind = "LinYuWide"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LinYuWidgetConfiguration.self, provider: LinYuWidgetProvider()) { LinYuWidgetView(entry: $0, layout: "wide") }
            .configurationDisplayName("淋浴 · 多功能").description("设备、附近设备、账单三页切换")
            .supportedFamilies([.systemMedium, .systemLarge]).contentMarginsDisabled()
    }
}
#if LINYU_WIDGET_EXTENSION
@main struct LinYuWidgets: WidgetBundle {
    var body: some Widget { LinYuTileWidget(); LinYuPanelWidget(); LinYuWideWidget() }
}
#endif
