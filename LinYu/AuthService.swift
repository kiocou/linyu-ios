import Foundation

/// 登录相关接口
enum AuthService {

    /// 密码登录
    ///
    /// ⚠️ 密码不是原文直接发：要先 **MD5 → 取后 10 位 → 转大写**。
    /// 这是官方客户端的做法，和改密码用的是同一套。
    static func login(phone: String, password: String) async throws -> LoginData {
        let encrypted = encryptPassword(password)
        AppLog.shared.i("尝试密码登录 \(phone)")

        let data = try await ApiClient.post("/user/login", form: [
            "telephone": phone,
            "password": encrypted,
            "type": "0",
            "phoneSystem": "android",
            "version": "6.5.28"
        ], withAuth: false, tag: "login")

        let resp = try ApiClient.decode(LoginData.self, from: data, path: "login")
        guard let d = resp.data else { throw ApiError.business(code: -1, message: "登录响应缺少 data") }
        return d
    }

    /// 短信验证码登录 / 注册
    static func smsLogin(phone: String, smsCode: String) async throws -> LoginData {
        AppLog.shared.i("尝试短信登录 \(phone)")

        let data = try await ApiClient.post("/user/registerAndLogin", form: [
            "telephone": phone,
            "smsCode": smsCode,
            "type": "5",
            "phoneSystem": "android",
            "version": "6.5.28"
        ], withAuth: false, tag: "smsLogin")

        let resp = try ApiClient.decode(LoginData.self, from: data, path: "smsLogin")
        guard let d = resp.data else { throw ApiError.business(code: -1, message: "登录响应缺少 data") }
        return d
    }

    /// 发送短信验证码
    ///
    /// `secret` 是按手机号动态算的：`MD5(前3位 + 后4位 + "klcx")`
    static func sendSmsCode(phone: String) async throws {
        guard phone.count == 11 else {
            throw ApiError.transport("请输入 11 位手机号")
        }
        let secret = smsSecret(phone)
        AppLog.shared.i("请求短信验证码 \(phone)")

        // 注意：verification 接口在 ApiClient 里会跳过 auth 拼接
        _ = try await ApiClient.get("/user/verification/code/get", query: [
            "telephone": phone,
            "secret": secret,
            "typeId": "3",
            "platform": "1"
        ], tag: "smsCode")
    }

    // MARK: - 工具

    /// MD5 → 取后 10 位 → 大写
    static func encryptPassword(_ raw: String) -> String {
        let md5 = Signer.md5Hex(raw)   // 小写
        let tail = md5.count >= 10 ? String(md5.suffix(10)) : md5
        return tail.uppercased()
    }

    /// `MD5(phone[0..<3] + phone[7..<11] + "klcx")`
    static func smsSecret(_ phone: String) -> String {
        let chars = Array(phone)
        let head = String(chars.prefix(3))
        let tail = String(chars.suffix(4))
        return Signer.md5Hex(head + tail + "klcx")
    }

    /// 登录成功后统一落库
    @MainActor
    static func persist(_ d: LoginData, phone: String) {
        Session.shared.save(
            loginCode: d.loginCode ?? "",
            userId: d.userId.map(String.init) ?? "",
            accountId: d.userAccount?.accountId.map(String.init) ?? "",
            projectId: d.userAccount?.projectId.map(String.init) ?? "",
            telephone: phone,
            displayName: d.userAccount?.name
        )
    }
}
