#if DEBUG
import SwiftUI
import WidgetKit

/// CI 离线布局验收：只使用固定假数据，不启动登录、扫描或水控。
@available(iOS 17.0, *)
struct WidgetPreviewScreen: View {
    private var entry: LinYuWidgetEntry {
        var value = WidgetSnapshot()
        value.owner = "preview"
        value.lastDevice = "A"
        let running = CommandLine.arguments.contains("--preview-running")
        value.devices = [WidgetDevice(id: "A", name: "龙川北苑 3号楼南 320房", detail: "卫生间热水器", emoji: "🚿", rssi: -61,
             running: running, orderNo: running ? "preview-order" : "", startedAt: running ? Int64(Date().addingTimeInterval(-125).timeIntervalSince1970 * 1000) : 0, preDeduct: 10, lastConsume: 1.84),
             WidgetDevice(id: "B", name: "龙川北苑 3号楼南 321房", detail: "洗手台热水器", emoji: "🪥", rssi: -79)]
        value.nearbyIDs = ["A", "B"]
        value.nearbyDate = Date().addingTimeInterval(-60)
        value.balance = "¥ 55.46"
        value.balanceTitle = "一卡通余额"
        value.bills = [WidgetBill(name: "龙川北苑 320房", emoji: "🚿", time: "10-27 08:30", money: "-¥ 1.84"),
                       WidgetBill(name: "龙川北苑 320房", emoji: "🪥", time: "10-26 20:30", money: "-¥ 0.50")]
        let tab = CommandLine.arguments.contains("--preview-nearby") ? 1 : CommandLine.arguments.contains("--preview-bills") ? 2 : 0
        return .init(date: Date(), snapshot: value, slot: "1", selection: .init(owner: "preview", device: "A", tab: tab))
    }
    var body: some View {
        VStack(spacing: 18) {
            Text("淋浴 · 小组件布局验收").font(.headline).foregroundStyle(.white)
            HStack(spacing: 16) {
                preview("tile", width: 160, height: 170, family: .systemSmall)
                preview("panel", width: 160, height: 170, family: .systemSmall)
            }
            preview("wide", width: 336, height: 170, family: .systemMedium)
            preview("wide", width: 336, height: 285, family: .systemLarge)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.16, green: 0.20, blue: 0.24).ignoresSafeArea())
    }
    private func preview(_ layout: String, width: CGFloat, height: CGFloat, family: WidgetFamily) -> some View {
        LinYuWidgetView(entry: entry, layout: layout, familyOverride: family)
            .frame(width: width, height: height)
            .background(Color(red: 0.12, green: 0.15, blue: 0.19))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.18)))
    }
}
#endif
