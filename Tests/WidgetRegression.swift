import Foundation

@main struct WidgetRegression {
    static func main() throws {
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            print("\(passed ? "PASS" : "FAIL"): \(name)")
            if !passed { failures += 1 }
        }
        var snapshot = WidgetSnapshot()
        snapshot.owner = "school:account"
        snapshot.lastDevice = "A"
        snapshot.devices = [WidgetDevice(id: "A", name: "320房", detail: "热水器", emoji: "🚿"),
                            WidgetDevice(id: "B", name: "321房", detail: "热水器", emoji: "🚿", running: true, orderNo: "orderB", startedAt: 123, selectable: false)]
        let start = WidgetCommand(url: WidgetCommand.url(.start, snapshot: snapshot, device: snapshot.devices[0]))!
        check(start.matches(snapshot), "组件开阀按钮保留目标身份")
        let stop = WidgetCommand(url: WidgetCommand.url(.stop, snapshot: snapshot, device: snapshot.devices[1]))!
        check(stop.matches(snapshot), "寝室筛选不隐藏正在使用设备的停止入口")
        check(snapshot.selected("B")?.running == true, "筛选外进行中的订单仍可展示")
        snapshot.devices[1].running = false
        check(snapshot.selected("B") == nil && !stop.matches(snapshot), "筛选外空闲设备不能被展示或停止")
        snapshot.devices[1].running = true
        snapshot.devices[1].orderNo = "newOrder"
        check(!stop.matches(snapshot), "旧组件不能关闭同设备新订单")
        snapshot.devices[0].running = true
        check(!start.matches(snapshot), "旧开阀按钮不能操作已运行的设备")
        snapshot.devices[0].running = false
        snapshot.devices[0].selectable = false
        check(!start.matches(snapshot), "寝室筛选也校验实际开阀入口")
        snapshot.devices[0].selectable = true
        snapshot.owner = "school:another"
        check(!start.matches(snapshot), "换账号后拒绝旧组件动作")
        snapshot.owner = "school:account"
        snapshot.token = UUID().uuidString
        check(!start.matches(snapshot), "随机身份变化后拒绝旧按钮")
        check(WidgetCommand(url: URL(string: "linyu-widget://start?sn=A")!) == nil, "外部不完整链接不触发水控")
        check(WidgetCommand(url: URL(string: "https://start")!) == nil, "非组件链接拒绝执行")
        let encoded = try JSONEncoder().encode(snapshot)
        check(try JSONDecoder().decode(WidgetSnapshot.self, from: encoded) == snapshot, "快照序列化完整保留设备与订单")
        let before = snapshot.controlIdentity
        snapshot.balance = "¥ 5.00"
        snapshot.devices[0].rssi = -65
        check(before == snapshot.controlIdentity, "余额和信号刷新不使控制身份失效")
        snapshot.devices[0].startedAt = 456
        check(before != snapshot.controlIdentity, "新会话时间使旧控制身份失效")
        check(snapshot.selected("")?.id == "A", "默认选中上次设备")
        let group = "group.com.hualala.linyu"
        let profile = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["com.apple.security.application-groups": [group + ".TEAM", "group.unrelated"]]], format: .xml, options: 0)
        check(WidgetGroupPolicy.candidates(profile: profile, original: group) == [group + ".TEAM"], "使用本应用签名后的组名且不读取无关应用组")
        check(WidgetGroupPolicy.candidates(profile: nil, original: group) == [group], "模拟器及无描述文件时使用原组名")
        check(WidgetGroupPolicy.candidates(profile: Data("broken".utf8), original: group) == [group], "损坏描述文件不崩溃")
        if failures > 0 { fatalError("\(failures) widget checks failed") }
    }
}
