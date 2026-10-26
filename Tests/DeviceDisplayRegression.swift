import SwiftUI

// 只替代颜色构造依赖；设备名称、类型、寝室规则均编译实际 DeviceInfoDisplay。
extension Color {
    init(hex: UInt) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}
@main struct DeviceDisplayRegression {
    static func main() throws {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures += 1 }
        }
        func device(_ json: String) throws -> DeviceInfo {
            try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        }
        let shower = try device(#"{"deviceName":"热水变-校区-3层-320房"}"#)
        check(!shower.isDrinkingWater && shower.typeEmoji == "🚿", "热水变不误判成饮水机")
        let drinking = try device(#"{"deviceName":"直饮热水-校区-320","bigTypeId":5}"#)
        check(drinking.isDrinkingWater && drinking.statusText == "正在接热水", "直饮热水状态文案")
        let basin = try device(#"{"deviceName":"洗手台54-校区-3层-320洗手台"}"#)
        check(basin.isWashbasin && basin.typeLabel == "洗手台热水器", "洗手台类型标签")
        let room = DeviceInfo.roomKey("热水表-校区-3层-320房")
        check(room == DeviceInfo.roomKey("洗手台54-校区-3层-320洗手台"), "同寝室不同类型设备归同组")
        check(room.flatMap { DeviceInfo.roomKey($0) } == room, "寝室关键词幂等")
        check(!DeviceInfo.inSameRoom(boundKey: room ?? "", deviceName: "热水表-校区-3层-321房"), "不同房间不误筛入")
        check(shower.displayName == "校区 320房", "展示名称清理类型前缀和楼层")
        if failures > 0 { fatalError("设备展示回归失败：\(failures)") }
    }
}
