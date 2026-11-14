import Foundation

/// 只缓存当前账号的展示资料，不保存登录凭据；学校与账号共同确定归属。
enum ProfileCache {
    struct Snapshot: Codable {
        let owner: String
        let info: AccountInfo
        let projectName: String
    }
    private static let key = "linyu.profileCache"
    static func read(owner: String) -> Snapshot? {
        guard !owner.isEmpty, let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Snapshot.self, from: data), value.owner == owner else { return nil }
        return value
    }
    static func save(owner: String, info: AccountInfo, projectName: String) {
        guard !owner.isEmpty,
              let data = try? JSONEncoder().encode(Snapshot(owner: owner, info: info, projectName: projectName)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

extension AccountInfo {
    static var empty: AccountInfo {
        AccountInfo(name: nil, idCardNumber: nil, telephone: nil, genderName: nil,
                    cardStatus: nil, cardStatusName: nil, gradeName: nil, className: nil)
    }
    mutating func fillIdentity(name: String?, studentId: String?) {
        if self.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.name = name }
        if idCardNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let studentId, !studentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { idCardNumber = studentId }
    }
    var needsIdentity: Bool {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
        idCardNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
}
