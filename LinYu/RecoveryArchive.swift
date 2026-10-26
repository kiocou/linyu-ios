import Foundation

/// 恢复态按学校+账号归档。不保存凭证；未确认归属的旧记录不交给新账号。
enum RecoveryArchive {
    private static let archiveKey = "linyu.recoveryByAccount"
    private static let ownerKey = "linyu.recoveryOwner"
    private static let lock = NSRecursiveLock()
    private static func isRecoveryKey(_ key: String) -> Bool {
        ["activeOrders", "finishedOrderIdentities", "pendingSettlements", "bleSessionJson", "bleDevices"].contains(key)
            || key.hasPrefix("startedAt_") || key.hasPrefix("autoDiscon_") || key.hasPrefix("lastDevice")
    }
    static func bindExisting(owner: String, defaults: UserDefaults = .standard) {
        guard !owner.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        // 仅启动时仍有有效登录凭据，才允许给旧版本数据补归属。
        if defaults.string(forKey: ownerKey) == nil { defaults.set(owner, forKey: ownerKey) }
        else if defaults.string(forKey: ownerKey) != owner { activate(owner: owner, defaults: defaults) }
    }
    static func suspend(owner: String, preserve: Bool, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        var archive = defaults.dictionary(forKey: archiveKey) ?? [:]
        if !owner.isEmpty {
            if preserve {
                archive[owner] = defaults.dictionaryRepresentation().filter { isRecoveryKey($0.key) }
            } else { archive.removeValue(forKey: owner) }
            defaults.set(archive, forKey: archiveKey)
        }
        clearVisible(defaults)
    }
    static func activate(owner: String, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        guard !owner.isEmpty else { return }
        if defaults.string(forKey: ownerKey) == owner { return }
        if let previous = defaults.string(forKey: ownerKey), !previous.isEmpty {
            var archive = defaults.dictionary(forKey: archiveKey) ?? [:]
            archive[previous] = defaults.dictionaryRepresentation().filter { isRecoveryKey($0.key) }
            defaults.set(archive, forKey: archiveKey)
        }
        // 保留未知归属的历史数据供诊断，不自动认领、也不销毁。
        if defaults.string(forKey: ownerKey) == nil {
            let orphan = defaults.dictionaryRepresentation().filter { isRecoveryKey($0.key) }
            if !orphan.isEmpty { defaults.set(orphan, forKey: "linyu.unassignedRecovery") }
        }
        clearVisible(defaults)
        if let snapshot = defaults.dictionary(forKey: archiveKey)?[owner] as? [String: Any] {
            for (key, value) in snapshot where isRecoveryKey(key) { defaults.set(value, forKey: key) }
        }
        defaults.set(owner, forKey: ownerKey)
    }
    private static func clearVisible(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where isRecoveryKey(key) { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: ownerKey)
    }
}
