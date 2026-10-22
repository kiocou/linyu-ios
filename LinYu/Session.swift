import Foundation
import Security
import Combine

/// 登录态与凭证存储。
///
/// ## 为什么用 Keychain 而不是 UserDefaults
///
/// `loginCode` 等同于会话令牌，拿到它就能以这个账号身份调所有接口（包括扣钱）。
/// UserDefaults 是明文 plist，越狱设备或备份里能直接读出来。
/// Keychain 由系统加密托管，是 iOS 上存凭证的唯一正确做法。
///
/// ## 字段来源
///
/// `POST /user/login` 的响应：
/// ```json
/// { "data": { "userId": 21691350, "loginCode": "...",
///             "userAccount": { "accountId": 18578, "projectId": 88, ... } } }
/// ```
final class Session: ObservableObject {

    static let shared = Session()

    private let service = "com.hualala.linyu.session"

    @Published private(set) var loginCode: String = ""
    @Published private(set) var userId: String = ""
    @Published private(set) var accountId: String = ""
    @Published private(set) var projectId: String = ""
    @Published private(set) var telephone: String = ""
    /// 界面展示用的名字（可选，登录接口不一定给）
    @Published private(set) var displayName: String = ""

    private init() {
        restore()
    }

    var isLoggedIn: Bool { !loginCode.isEmpty }

    // MARK: - 保存 / 恢复

    func save(
        loginCode: String,
        userId: String,
        accountId: String,
        projectId: String,
        telephone: String,
        displayName: String? = nil
    ) {
        self.loginCode = loginCode
        self.userId = userId
        self.accountId = accountId
        self.projectId = projectId
        self.telephone = telephone
        if let n = displayName { self.displayName = n }

        set("loginCode", loginCode)
        set("userId", userId)
        set("accountId", accountId)
        set("projectId", projectId)
        set("telephone", telephone)
        if let n = displayName { set("displayName", n) }

        AppLog.shared.i("登录态已保存：projectId=\(projectId)")
    }

    /// 换绑手机号后同步本地的 telephone。
    ///
    /// ⚠️ 必须写：认证参数 `telephone` / `telPhone` 是从这里取的，
    /// 不更新的话后续所有请求还在用旧号（照搬 Android `PrefsHelper.telephone = newPhone`
    /// + `NetworkModule.restoreFromPrefs()`）。
    func updateTelephone(_ newPhone: String) {
        guard !newPhone.isEmpty else { return }
        telephone = newPhone
        set("telephone", newPhone)
        AppLog.shared.i("已更新本地手机号")
    }

    func logout() {
        loginCode = ""
        userId = ""
        accountId = ""
        projectId = ""
        telephone = ""
        displayName = ""
        for k in ["loginCode", "userId", "accountId", "projectId", "telephone", "displayName"] {
            delete(k)
        }
        AppLog.shared.i("已退出登录")
    }

    private func restore() {
        loginCode = get("loginCode") ?? ""
        userId = get("userId") ?? ""
        accountId = get("accountId") ?? ""
        projectId = get("projectId") ?? ""
        telephone = get("telephone") ?? ""
        displayName = get("displayName") ?? ""
        if !loginCode.isEmpty {
            AppLog.shared.i("已恢复登录态：projectId=\(projectId)")
        }
    }

    // MARK: - 请求参数

    /// POST 用的 auth 字段（与 Android `NetworkModule.authFields()` 一致）
    ///
    /// ⚠️ `telPhone` 必须也带上：绝大多数 GET 只认 `telephone`，
    /// 但 `/settlement/campus/userInfo` 要的是 `telPhone`，少了它服务端
    /// 会返回「手机号不能为空」——而且 HTTP 状态码还是 200，只能看 errorMessage。
    var authFields: [String: String] {
        [
            "loginCode": loginCode,
            "userId": userId,
            "accountId": accountId,
            "projectId": projectId,
            "telephone": telephone,
            "telPhone": telephone,
            "phoneSystem": "android",
            "version": "6.5.28"
        ]
    }

    /// GET 追加的 query 参数
    var authQuery: [String: String] { authFields }

    // MARK: - Keychain 基础操作

    private func set(_ key: String, _ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private func get(_ key: String) -> String? {
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

    private func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
