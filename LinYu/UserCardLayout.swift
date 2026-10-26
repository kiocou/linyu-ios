import Foundation

/// 「我的」页里可编辑的卡片类型（声明顺序即默认顺序）
enum UserCardType: String, CaseIterable {
    case account
    case useCode
    case notify
    case trend
    case background
    case boundRoom
    case update
    case about
    case log

    var title: String {
        switch self {
        case .account: return "账号信息"
        case .useCode: return "使用码"
        case .notify: return "通知"
        case .trend: return "消费趋势"
        case .background: return "背景装扮"
        case .boundRoom: return "绑定寝室"
        case .update: return "软件更新"
        case .about: return "关于项目"
        case .log: return "运行日志"
        }
    }
}

/// 卡片分页策略 —— 逐条对照 Android 的 `UserCardLayoutPolicy`
enum UserCardLayout {

    /// 「我的」页默认三张
    static let profileDefaults: [UserCardType] = [.account, .useCode, .boundRoom]
    /// 「设置」页默认六张
    static let settingsDefaults: [UserCardType] = [.notify, .trend, .background, .log, .about, .update]

    // 两页一起恢复：卡片移到另一页后不能按各自默认列表过滤回原页。
    // 与 Android restorePages 一致，去重后只补充尚未分配的卡片。
    static func restorePages(profileSaved: String, settingsSaved: String)
        -> (profile: [UserCardType], settings: [UserCardType]) {
        func parse(_ saved: String) -> [UserCardType] {
            saved.split(separator: ",").compactMap {
                UserCardType(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        var assigned = Set<UserCardType>()
        var profile = parse(profileSaved).filter { assigned.insert($0).inserted }
        var settings = parse(settingsSaved).filter { assigned.insert($0).inserted }
        profile += profileDefaults.filter { assigned.insert($0).inserted }
        settings += settingsDefaults.filter { assigned.insert($0).inserted }
        return (profile, settings)
    }

    static func save(_ list: [UserCardType], key: String) {
        UserDefaults.standard.set(list.map(\.rawValue).joined(separator: ","), forKey: key)
    }

    static func moveToSettings(_ type: UserCardType, profile: [UserCardType], settings: [UserCardType])
        -> (profile: [UserCardType], settings: [UserCardType]) {
        (profile.filter { $0 != type }, settings.filter { $0 != type } + [type])
    }

    static func moveToProfile(_ type: UserCardType, profile: [UserCardType], settings: [UserCardType])
        -> (profile: [UserCardType], settings: [UserCardType]) {
        (profile.filter { $0 != type } + [type], settings.filter { $0 != type })
    }

    static func saveHidden(_ set: Set<String>, key: String) {
        UserDefaults.standard.set(set.joined(separator: ","), forKey: key)
    }

    static func loadHidden(_ key: String) -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func move<T>(_ list: [T], from: Int, to: Int) -> [T] {
        guard from != to, list.indices.contains(from), list.indices.contains(to) else { return list }
        var m = list
        let item = m.remove(at: from)
        m.insert(item, at: to)
        return m
    }
}
