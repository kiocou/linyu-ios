import Foundation

@main struct WidgetRegression {
    static func main() throws {
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            print("\(passed ? "PASS" : "FAIL"): \(name)")
            if !passed { failures += 1 }
        }
        var snapshot = WidgetSnapshot()
        check(snapshot.emptyTitle == "未登录", "无账户且没有同步错误才显示未登录")
        snapshot.message = "小组件无法同步，请检查安装权限"
        check(snapshot.emptyTitle == "等待同步", "共享权限错误不误报退出登录")
        snapshot.message = nil
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
        check(start.matches(snapshot), "旧开启入口允许进入同设备已有订单，由主程序恢复而非重复开阀")
        snapshot.devices[0].occupied = true
        check(!start.matches(snapshot), "他人占用的设备不能通过旧开启入口使用")
        snapshot.devices[0].occupied = false
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
        let stableStart = WidgetCommand(url: WidgetCommand.url(.start, snapshot: snapshot, device: snapshot.devices[0]))!
        snapshot.devices[1].orderNo = "unrelated-order"
        check(stableStart.matches(snapshot), "别的设备订单变化不作废上次设备开启入口")
        snapshot.bills = []
        check(stableStart.matches(snapshot), "账单刷新不作废云端上次设备入口")
        snapshot.devices[0].startedAt = 456
        check(before != snapshot.controlIdentity, "新会话时间使旧控制身份失效")
        check(snapshot.selected("")?.id == "A", "默认选中上次设备")
        var away = WidgetSnapshot()
        away.owner = "school:account"; away.lastDevice = "cloud"
        away.devices = [WidgetDevice(id: "cloud", name: "320房", detail: "热水器", emoji: "🚿", running: true, orderNo: "cloud-order", startedAt: 123, selectable: false)]
        check(away.nearbyIDs.isEmpty && away.displayedDevice("old-selection")?.id == "cloud", "不在寝室且旧选项失效时，云端使用状态不依赖附近设备")
        check(away.displayedDevice("old-selection")?.running == true, "正在用水优先展示，不被旧筛选隐藏")
        let awayStop = WidgetCommand(url: WidgetCommand.url(.stop, snapshot: away, device: away.displayedDevice("old-selection")))!
        check(awayStop.matches(away) && awayStop.sn == "cloud", "离开寝室时停止入口仍绑定真实订单")
        away.devices[0].running = false; away.devices[0].selectable = true
        check(away.displayedDevice("old-selection")?.id == "cloud", "关闭后仍显示持久化的上次设备")
        check(away.selected("old-selection") == nil, "展示回退不让旧指定设备链接串台")
        away.devices[0].selectable = false
        check(away.displayedDevice("old-selection") == nil, "空闲跨寝室设备仍遵守筛选")
        away.devices.append(WidgetDevice(id: "B", name: "321房", detail: "热水器", emoji: "🚿", running: true))
        check(away.displayedDevice("missing")?.id == "B", "上次设备不可见时保留唯一进行中订单入口")
        away.devices.append(WidgetDevice(id: "C", name: "322房", detail: "热水器", emoji: "🚿", running: true))
        check(away.displayedDevice("missing") == nil, "多个未选中订单不猜测控制目标")
        let detail = WidgetCommand(url: WidgetCommand.url(.billDetail, snapshot: snapshot, device: nil, billID: "bill/123 中文"))!
        check(detail.kind == .billDetail && detail.billID == "bill/123 中文", "具体账单点击保留完整账单身份")
        let deviceLink = WidgetCommand(url: WidgetCommand.url(.device, snapshot: snapshot, device: snapshot.devices[0]))!
        check(deviceLink.kind == .device && deviceLink.sn == "A", "附近设备点击进入对应设备详情")
        check(WidgetCommand(url: WidgetCommand.url(.refreshNearby, snapshot: snapshot, device: nil))?.kind == .refreshNearby, "刷新与普通附近导航使用不同动作")
        check(WidgetCommand(url: URL(string: "linyu-widget://start?owner=x&owner=y&sn=A&order=&start=0")!) == nil, "拒绝重复参数绕过身份校验")
        let device = WidgetDevice(id: "water", name: "320房", detail: "洗手台热水器", emoji: "🪥")
        let wrong = WidgetBill(name: "320房", emoji: "🚿", time: "2026-11-03", money: "-¥1.84", detail: "卫生间热水器", amount: 1.84)
        var right = wrong; right.detail = device.detail; right.amount = 0.5
        check(WidgetDisplayPolicy.lastConsume(cached: 0, device: device, bills: [wrong]) == 0, "同房不同设备类型不能串用消费")
        check(WidgetDisplayPolicy.lastConsume(cached: 0, device: device, bills: [wrong, right]) == 0.5, "已有账单补齐对应设备消费")
        check(WidgetDisplayPolicy.lastConsume(cached: 0.8, device: device, bills: [right]) == 0.8, "较旧账单不覆盖已记录的设备消费")
        right.deviceSN = "other"
        check(WidgetDisplayPolicy.lastConsume(cached: 0, device: device, bills: [right]) == 0, "明确不同序列号时不按相同名字猜测")
        right.deviceSN = "water"; right.name = "旧设备名"
        check(WidgetDisplayPolicy.lastConsume(cached: 0, device: device, bills: [right]) == 0.5, "序列号精确匹配允许名称改变")
        var aliased = device
        aliased.aliases = ["confirmed-address"]
        right.deviceSN = "confirmed-address"
        check(WidgetDisplayPolicy.lastConsume(cached: 0, device: aliased, bills: [right]) == 0.5, "台账确认的地址与序列号共享消费记录")
        right.deviceSN = "unknown-address"
        check(WidgetDisplayPolicy.lastConsume(cached: 0, device: aliased, bills: [right]) == 0, "未知地址不能串用消费记录")
        var aliasSnapshot = WidgetSnapshot()
        aliasSnapshot.devices = [aliased]
        check(aliasSnapshot.selected("confirmed-address")?.id == "water", "旧选中地址迁移到台账序列号")
        check(aliasSnapshot.selected("unknown-address") == nil, "未知选中地址不能操作设备")
        aliasSnapshot.devices[0].selectable = false
        check(aliasSnapshot.selected("confirmed-address") == nil, "地址迁移不能绕过寝室筛选")
        let oldBill = Data(#"{"name":"320房","emoji":"🚿","time":"2026-11-03","money":"-¥1.84"}"#.utf8)
        check(try JSONDecoder().decode(WidgetBill.self, from: oldBill).id == nil, "升级兼容旧版组件账单缓存")
        let group = "group.com.hualala.linyu"
        let profile = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["com.apple.security.application-groups": [group + ".TEAM", "group.unrelated"]]], format: .xml, options: 0)
        check(WidgetGroupPolicy.candidates(profile: profile, original: group) == [group + ".TEAM"], "使用本应用签名后的组名且不读取无关应用组")
        check(WidgetGroupPolicy.candidates(profile: nil, original: group) == [group], "模拟器及无描述文件时使用原组名")
        check(WidgetGroupPolicy.candidates(profile: Data("broken".utf8), original: group) == [group], "损坏描述文件不崩溃")
        let now = Date()
        check(WidgetDisplayPolicy.syncedAgo(now, now: now) == "刚刚", "组件刚同步文案中文")
        check(WidgetDisplayPolicy.syncedAgo(now.addingTimeInterval(-120), now: now) == "2 分钟前", "组件分钟文案不受英文系统影响")
        check(WidgetDisplayPolicy.syncedAgo(now.addingTimeInterval(-7200), now: now) == "2 小时前", "组件小时文案中文")
        check(WidgetCommandKind.home.isNavigation && WidgetCommandKind.device.isNavigation, "首页与详情入口即时消费，不排队水控")
        check(!WidgetCommandKind.start.isNavigation && !WidgetCommandKind.stop.isNavigation && !WidgetCommandKind.refresh.isNavigation, "水控与刷新保留异步操作校验")
        let home = WidgetCommand(url: WidgetCommand.url(.home, snapshot: snapshot, device: nil))!
        var delivery = WidgetDeliveryPolicy()
        let deliveryDate = Date(timeIntervalSince1970: 100)
        check(delivery.accept(home, pending: nil, handling: false, now: deliveryDate), "首次普通入口立即交付导航")
        check(delivery.accept(stableStart, pending: home, handling: false, now: deliveryDate), "开关请求替换未消费的首页入口，不丢失点击动作")
        check(!delivery.accept(home, pending: stableStart, handling: false, now: deliveryDate), "首页入口不能抢占待执行开关")
        check(!delivery.accept(stableStart, pending: nil, handling: false, now: deliveryDate), "重复交付不能再次发起水控")
        check(!delivery.accept(home, pending: nil, handling: false, now: deliveryDate.addingTimeInterval(20)), "同次前台会话的迟到首页回调不再覆盖使用页")
        delivery.enteredBackground()
        check(delivery.accept(home, pending: nil, handling: false, now: deliveryDate.addingTimeInterval(21)), "再次从桌面正常点击可进入首页")
        check(!delivery.accept(stableStart, pending: nil, handling: true, now: deliveryDate.addingTimeInterval(22)), "操作处理中不接受第二个开关动作")
        check(!ColorContrastPolicy.usesDarkForeground(red: 0.6, green: 0.6, blue: 0.6), "中灰强调色按 Android 线性亮度使用白字")
        check(ColorContrastPolicy.usesDarkForeground(red: 0.8, green: 0.8, blue: 0.8), "浅色强调色使用深色文字")
        check(!ColorContrastPolicy.usesDarkForeground(red: 0, green: 0, blue: 0) && ColorContrastPolicy.usesDarkForeground(red: 1, green: 1, blue: 1), "黑白强调色对比正确")
        check(ConsumptionCachePolicy.shouldUpdate(sameDevice: true, amount: 1.84, billTime: 200, cachedTime: 100), "新账单更新上次设备消费")
        check(!ConsumptionCachePolicy.shouldUpdate(sameDevice: true, amount: 0.5, billTime: 100, cachedTime: 200), "旧账单不覆盖刚结算金额")
        check(!ConsumptionCachePolicy.shouldUpdate(sameDevice: false, amount: 1.84, billTime: 200, cachedTime: 100), "不同设备账单不串消费")
        check(!ConsumptionCachePolicy.shouldUpdate(sameDevice: true, amount: 0, billTime: 200, cachedTime: 100), "未结算零金额不抹掉历史消费")
        if failures > 0 { fatalError("\(failures) widget checks failed") }
    }
}
