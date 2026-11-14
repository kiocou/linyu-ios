import SwiftUI
import WidgetKit
import AppIntents
import os
#if !LINYU_WIDGET_EXTENSION
import UIKit
#endif

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
        let started = Date()
        let snapshot = WidgetSharedStore.read()
        var value = WidgetSharedStore.selection(slot, owner: snapshot.owner)
        let target = min(2, max(0, page))
        guard value.owner != snapshot.owner || value.tab != target else { return .result() }
        value.owner = snapshot.owner
        value.tab = target
        WidgetSharedStore.select(value, slot: slot)
        Logger(subsystem: "com.hualala.linyu", category: "Widget").info("切页缓存写入耗时 \(Date().timeIntervalSince(started) * 1000) ms，页面 \(page)")
        // Button(intent:) 完成后系统会刷新当前组件，无需额外重载所有组件。
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
        guard snapshot.token == token, !snapshot.owner.isEmpty, let device = snapshot.selected(sn) else { return .result() }
        WidgetSharedStore.select(.init(owner: snapshot.owner, device: device.id, tab: 0), slot: slot)
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
        let started = Date()
        let snapshot = WidgetSharedStore.read()
        let selection = WidgetSharedStore.selection(slot, owner: snapshot.owner)
        Logger(subsystem: "com.hualala.linyu", category: "Widget").info("时间线缓存读取耗时 \(Date().timeIntervalSince(started) * 1000) ms，页面 \(selection.tab)")
        return .init(date: Date(), snapshot: snapshot, slot: slot, selection: selection)
    }
}

private struct Glass: ViewModifier {
    var radius: CGFloat = 15
    var stopping = false
    func body(content: Content) -> some View {
        content.background(stopping ? Color(red: 239/255, green: 68/255, blue: 68/255).opacity(0.22) : .white.opacity(0.10), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.16), lineWidth: 1))
    }
}
/// 对照 Android res/drawable/ic_widget_*.xml 的 24×24 描边路径。
private struct AndroidWidgetGlyph: View {
    let kind: String
    var body: some View {
        GeometryReader { geo in
            glyph.strokedPath(StrokeStyle(lineWidth: kind == "power" || kind == "stop" ? 2.4 : 2.2, lineCap: .round, lineJoin: .round))
                .applying(CGAffineTransform(scaleX: geo.size.width / 24, y: geo.size.height / 24)).fill(.white)
        }
    }
    private var glyph: Path {
        var p = Path()
        switch kind {
        case "bluetooth":
            p.move(to: CGPoint(x: 6.5, y: 6.5))
            for point in [CGPoint(x: 17.5, y: 17.5), CGPoint(x: 12, y: 23), CGPoint(x: 12, y: 1), CGPoint(x: 17.5, y: 6.5), CGPoint(x: 6.5, y: 17.5)] { p.addLine(to: point) }
        case "clock":
            p.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
            p.move(to: CGPoint(x: 12, y: 6)); p.addLine(to: CGPoint(x: 12, y: 12)); p.addLine(to: CGPoint(x: 16, y: 14))
        case "card":
            p.addRoundedRect(in: CGRect(x: 2, y: 5, width: 20, height: 14), cornerSize: CGSize(width: 2, height: 2))
            p.move(to: CGPoint(x: 2, y: 10)); p.addLine(to: CGPoint(x: 22, y: 10))
        case "stop":
            p.addRoundedRect(in: CGRect(x: 6, y: 6, width: 12, height: 12), cornerSize: CGSize(width: 2, height: 2))
        default:
            p.addArc(center: CGPoint(x: 12, y: 13), radius: 9, startAngle: .degrees(-45), endAngle: .degrees(225), clockwise: false)
            p.move(to: CGPoint(x: 12, y: 2)); p.addLine(to: CGPoint(x: 12, y: 12))
        }
        return p
    }
}
@available(iOS 17.0, *)
struct LinYuWidgetView: View {
    @Environment(\.widgetFamily) private var systemFamily
    let entry: LinYuWidgetEntry
    let layout: String
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? systemFamily }
    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var device: WidgetDevice? { snapshot.displayedDevice(entry.selection.device) }
    private var staleBusy: Bool { snapshot.busy && entry.date.timeIntervalSince(snapshot.date) > 30 }
    private var stateColor: Color { device?.running == true ? Color(red: 0.376, green: 0.647, blue: 0.98) : device?.occupied == true ? .orange : Color(red: 0.29, green: 0.87, blue: 0.50) }
    private func url(_ kind: WidgetCommandKind) -> URL { WidgetCommand.url(kind, snapshot: snapshot, device: device) }
    @ViewBuilder private func destination<Content: View>(_ target: URL, @ViewBuilder label: () -> Content) -> some View {
        // Apple 的场景链接接口支持 systemSmall 及更大组件的多个 Link。
        // 所有尺寸统一经 onOpenURL 交付目标；不依赖重签后 Intent 的进程选择。
        Link(destination: target, label: label)
    }
    private var action: WidgetCommandKind {
        if staleBusy { return .refresh }
        if snapshot.owner.isEmpty { return .home }
        guard let device else { return .nearby }
        return device.running ? .stop : .start
    }
    private var title: String {
        if snapshot.owner.isEmpty { return snapshot.emptyTitle }
        guard let device else { return "请先选择设备" }
        return layout == "panel" ? String(device.name.split(separator: " ").last ?? Substring(device.name)) : device.name
    }
    var body: some View {
        Group {
            if layout == "panel" { panel }
            else { wide }
        }
        .padding(layout == "panel" ? 12 : 0)
        .foregroundStyle(.white)
        .font(.system(size: 12))
        .buttonStyle(.plain)
        .containerBackground(for: .widget) {
            Color(red: 15/255, green: 23/255, blue: 32/255)
                // iOS 会把透明背景合成到系统材质上，浅色下发白；固定底色保持白字对比度。
                .overlay(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(LinearGradient(stops: [.init(color: .white.opacity(0.20), location: 0), .init(color: .white.opacity(0.05), location: 0.45), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .overlay(ContainerRelativeShape().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .widgetURL(url(entry.selection.tab == 2 && layout == "wide" ? .bills : .home))
        .transition(.identity)
        .contentTransition(.identity)
        .animation(nil, value: entry.selection.tab)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .privacySensitive()
    }
    private var header: some View {
        HStack(spacing: 4) {
            if device != nil { Circle().fill(stateColor).frame(width: 6, height: 6) }
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).truncationMode(.head)
            Spacer(minLength: 0)
            if device != nil {
                Text(device?.running == true ? "● 使用中" : device?.occupied == true ? "● 占用中" : "● 空闲")
                    .font(.system(size: 10)).foregroundStyle(stateColor).fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(stateColor.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
        }
    }
    private var readout: some View {
        destination(url(device?.running == true ? .stop : .bills)) {
          VStack(spacing: 5) {
            if staleBusy { Text("状态未知，请刷新").multilineTextAlignment(.center) }
            else if let message = snapshot.message { Text(message).multilineTextAlignment(.center).lineLimit(3) }
            else if let device, device.running, device.startedAt > 0 {
                Text(Date(timeIntervalSince1970: Double(device.startedAt) / 1000), style: .timer)
                    .font(.system(size: 24, weight: .medium)).monospacedDigit()
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, alignment: .center)
                Text("预扣 · \(MoneyFormat.withSymbol(device.preDeduct))").font(.system(size: 10))
            } else {
                Text("上次消费").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65))
                Text((device?.lastConsume ?? 0) > 0 ? "¥ \(MoneyFormat.format(device!.lastConsume))" : "¥ —")
                    .font(.system(size: 22, weight: .medium)).minimumScaleFactor(0.7).lineLimit(1)
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).modifier(Glass())
        }.disabled(snapshot.busy && !staleBusy)
    }
    private var power: some View {
        destination(url(action)) {
            AndroidWidgetGlyph(kind: device?.running == true ? "stop" : "power").frame(width: 24, height: 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(Glass(radius: 12, stopping: device?.running == true))
        }.disabled(snapshot.busy && !staleBusy).accessibilityLabel(device?.running == true ? "结束用水" : "开始用水")
    }
    private var panel: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            Text(device?.detail ?? "点此打开淋浴").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                .padding(.leading, 10)
            readout
            power.frame(height: 34)
        }
    }
    private var wide: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(0..<3) { index in
                    Button(intent: WidgetPageIntent(slot: entry.slot, page: index)) {
                        AndroidWidgetGlyph(kind: ["clock", "bluetooth", "card"][index]).frame(width: 20, height: 20)
                            .frame(width: 38, height: 38)
                            .background(.white.opacity(entry.selection.tab == index ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 10))
                    }.frame(maxHeight: .infinity).accessibilityLabel(["设备", "附近设备", "账单"][index])
                }
            }.frame(width: 48).padding(.vertical, 4)
            Rectangle().fill(.white.opacity(0.16)).frame(width: 1)
            Group {
            if entry.selection.tab == 1 { nearby }
            else if entry.selection.tab == 2 { bills }
            else {
                VStack(alignment: .leading, spacing: 5) {
                    header
                    Text(device?.detail ?? "点按钮选附近设备").font(.system(size: 9)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).padding(.leading, 10)
                    HStack(spacing: 10) { readout; power.frame(width: 64) }
                }
            }
            }.padding(10).transition(.identity)
        }
    }
    private var nearby: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 3) {
                Text("附近设备").font(.system(size: 11))
                if let date = snapshot.nearbyDate { Text("(\(WidgetDisplayPolicy.syncedAgo(date, now: entry.date)))").font(.system(size: 8)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).minimumScaleFactor(0.7) }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    Text("●强").foregroundStyle(.green)
                    Text("●中").foregroundStyle(.orange)
                    Text("●弱").foregroundStyle(.red)
                }.fixedSize()
                destination(url(.refreshNearby)) { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
            }
            .font(.system(size: 8))
            let devices = snapshot.nearbyIDs.compactMap { sn in snapshot.devices.first { $0.id == sn && ($0.selectable || $0.running) } }
            if devices.isEmpty { Text("未扫描到附近设备").foregroundStyle(.white.opacity(0.6)); Spacer(minLength: 0) }
            ForEach(Array(devices.prefix(2))) { item in
                HStack(spacing: 6) {
                  destination(WidgetCommand.url(.device, snapshot: snapshot, device: item)) {
                   HStack(spacing: 6) {
                    Text(item.emoji).frame(width: 25, height: 25).background(.white.opacity(0.08), in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                        HStack(spacing: 3) {
                            Text(item.detail).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                            if let rssi = item.rssi { Text("● \(rssi) dBm").foregroundStyle(rssi >= -70 ? .green : rssi >= -85 ? .orange : .red).fixedSize() }
                        }.font(.system(size: 8))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                   }
                  }
                  Button(intent: WidgetPickIntent(slot: entry.slot, sn: item.id, token: snapshot.token)) {
                    Text("选用").font(.system(size: 10)).padding(.horizontal, 9).padding(.vertical, 4).modifier(Glass(radius: 20))
                  }
                }.padding(7).frame(maxWidth: .infinity, maxHeight: .infinity).modifier(Glass())
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var bills: some View {
        VStack(alignment: .leading, spacing: 7) {
            destination(url(.bills)) {
              HStack {
                VStack(alignment: .leading, spacing: 2) { Text(snapshot.balanceTitle).font(.system(size: 9)).foregroundStyle(.white.opacity(0.65)); HStack(spacing: 5) { AndroidWidgetGlyph(kind: "card").frame(width: 14, height: 14); Text(snapshot.balance).font(.system(size: 19, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6) } }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
              }.padding(8).modifier(Glass())
            }
            Text("最近消费").font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
            if snapshot.bills.isEmpty { Text("在 App 里刷新账单").foregroundStyle(.white.opacity(0.6)) }
            ForEach(Array(snapshot.bills.prefix(2).enumerated()), id: \.offset) { _, bill in
              destination(WidgetCommand.url(.billDetail, snapshot: snapshot, device: nil, billID: bill.id ?? "")) {
                HStack(spacing: 5) {
                    Text(bill.emoji).frame(width: 25, height: 25).background(.white.opacity(0.08), in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bill.name).font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                        Text(String(bill.time.prefix(16))).font(.system(size: 8)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(bill.money).font(.system(size: 11)).fixedSize()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            }
        }
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
            .supportedFamilies([.systemMedium]).contentMarginsDisabled()
    }
}
#if LINYU_WIDGET_EXTENSION
@main struct LinYuWidgets: WidgetBundle {
    var body: some Widget { LinYuPanelWidget(); LinYuWideWidget() }
}
#endif
