import Foundation
import Security

/// 登录凭据的本地保存 —— 用于「下次一键登录」。
///
/// ## 为什么单独一个 service
///
/// 和 `Session` 的 `com.hualala.linyu.session` 分开：退出登录会清 Session，
/// 但**不该顺手把用户存的密码也删掉**——否则每次重登都要重新输，
/// 「记住密码」就名存实亡了。
///
/// ## 为什么用 Keychain 而不是 UserDefaults
///
/// 密码是明文凭据。UserDefaults 落在 plist 里，越狱/备份能直接读出来；
/// Keychain 是系统加密存储，而且 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// 保证它不会进 iCloud 备份。
enum SavedCredential {

    private static let service = "com.hualala.linyu.credential"
    private static let accountPhone = "phone"
    private static let accountPassword = "password"

    /// 登录成功后保存。只保存**密码登录**的情况——验证码是一次性的，存它没意义
    static func save(phone: String, password: String) {
        guard !phone.isEmpty, !password.isEmpty else { return }
        set(accountPhone, phone)
        set(accountPassword, password)
        AppLog.shared.i("已保存登录凭据（手机号 \(AppLog.mask(phone))）")
    }

    /// 进入登录页时回填的手机号
    static var phone: String? { get(accountPhone) }

    /// 进入登录页时回填的密码（有值就说明上次是密码登录且用户没清过）
    static var password: String? { get(accountPassword) }

    /// 退出登录 / 用户主动清除时调用
    static func clear() {
        delete(accountPhone)
        delete(accountPassword)
    }

    // MARK: - Keychain

    private static func set(_ key: String, _ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // 不进 iCloud 备份：密码明文不该跟着备份走
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
