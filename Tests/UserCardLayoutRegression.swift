import Foundation

enum UserCardLayoutRegression {
    static func run(check: (Bool, String) -> Void) {
        let defaults = UserCardLayout.restorePages(profileSaved: "", settingsSaved: "")
        check(defaults.profile == [.account, .useCode, .boundRoom], "我的页面默认三张卡片")
        check(defaults.settings == [.notify, .trend, .background, .log, .about, .update], "设置默认顺序与安卓一致")
        let moved = UserCardLayout.moveToSettings(.account, profile: defaults.profile, settings: defaults.settings)
        check(moved.profile == [.useCode, .boundRoom] && moved.settings.last == .account, "移到设置放在末尾")
        let restored = UserCardLayout.restorePages(profileSaved: moved.profile.map(\.rawValue).joined(separator: ","),
                                                   settingsSaved: moved.settings.map(\.rawValue).joined(separator: ","))
        check(restored.profile == moved.profile && restored.settings == moved.settings, "重启恢复不把跨页卡片搬回默认页")
        let back = UserCardLayout.moveToProfile(.account, profile: moved.profile, settings: moved.settings)
        check(back.profile == [.useCode, .boundRoom, .account] && !back.settings.contains(.account), "移回我的追加且不重复")
        let broken = UserCardLayout.restorePages(profileSaved: " account,account,unknown,log ", settingsSaved: "log,notify,notify")
        let all = broken.profile + broken.settings
        check(all.count == UserCardType.allCases.count && Set(all).count == all.count, "重复未知及跨页冲突恢复后每卡恰好一份")
        check(broken.profile.prefix(2) == [.account, .log] && !broken.settings.contains(.log), "恢复保留已指定页和相对顺序")
        let duplicate = UserCardLayout.moveToSettings(.account, profile: [.account, .account], settings: [.account, .log, .account])
        check(duplicate.profile.isEmpty && duplicate.settings == [.log, .account], "跨页移动清除重复并追加到末尾")
        check(UserCardLayout.move([1, 2, 3], from: 0, to: 2) == [2, 3, 1], "卡片排序移动")
        check(UserCardLayout.move([1, 2], from: -1, to: 1) == [1, 2] &&
              UserCardLayout.move([1, 2], from: 1, to: 2) == [1, 2], "首尾越界移动不破坏卡片")
    }
}
