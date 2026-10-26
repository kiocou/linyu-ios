import Foundation

/// HTTP 层的错误
enum ApiError: LocalizedError {
    /// 业务错误（success=false），带服务端 errorCode
    case business(code: Int, message: String)
    /// 网络/解码层面
    case transport(String)
    /// 未登录
    case notLoggedIn
    /// HTTP 401 / 403 —— 会话已失效（被挤号或凭证过期）
    case unauthorized(status: Int)
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .business(let code, let msg): return "\(msg)（\(code)）"
        case .transport(let msg): return msg
        case .notLoggedIn: return "未登录"
        case .unauthorized(let status): return "登录已失效（HTTP \(status)）"
        case .http(let status): return "服务器请求失败（HTTP \(status)），请稍后重试"
        }
    }
}

/// HTTP 客户端。对照 Android 的 `NetworkModule` + Retrofit 接口。
///
/// ## 三处容易写错的约定
///
/// 1. **POST 全是 form-urlencoded**（除了手动代扣那个接口，本项目不用）
/// 2. **GET 要把 auth 拼进 query**，而且 `telPhone` 也要带
/// 3. **所有请求都要带 `Config-Project` / `Config-Keys` 头** ——
///    Android 端缺了这两个头时，蓝牙结算（upload）直接报 226「加密校验失败」
struct ApiClient {

    static let baseURL = "https://v3-api.china-qzxy.cn"

    private static let configKeys =
        "module_list,advertise_type,question_list,service_phone_list," +
        "banner_list_app,activity_list_app,aliCard_popup_config"

    static var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    // MARK: - 请求

    /// POST **JSON body** —— 本项目唯一用它的就是手动代扣
    /// （`/order/thirdTrade/single/json/pay`）。
    ///
    /// ⚠️ 别照其他接口改成 form-urlencoded：那个接口只收 JSON，
    /// 换成表单会直接报参数错。而且它要的 `phoneSystem` 是 `WeChat`
    /// （照抄官方 H5 抓包），不是 `android`。
    static func postJSON(
        _ path: String,
        body: [String: Any],
        tag: String? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let generation = Session.shared.requestGeneration
        try validateGeneration(generation)
        guard let url = URL(string: baseURL + path) else {
            throw ApiError.transport("URL 非法：\(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 日志里不打印 loginCode：它是会令牌，进日志等于泄露会话
        let preview = body.keys.sorted().map { key in
            key == "loginCode" ? "\(key)=***" : "\(key)=\(body[key] ?? "")"
        }.joined(separator: "&")

        let started = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            try validateGeneration(generation)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            AppLog.shared.i(
                "HTTP \(code) POST(json) \(path) (\(ms)ms)\(tag.map { " [\($0)]" } ?? "")",
                "req: \(preview)\nresp: \(text.prefix(600))"
            )
            if code == 401 || code == 403 {
                throw ApiError.unauthorized(status: code)
            }
            guard (200..<300).contains(code) else { throw ApiError.http(status: code) }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ApiError {
            throw error
        } catch {
            try validateGeneration(generation)
            AppLog.shared.e("HTTP FAIL POST(json) \(path)", "\(error.localizedDescription)")
            throw ApiError.transport(error.localizedDescription)
        }
    }

    /// POST form-urlencoded
    static func post(
        _ path: String,
        form: [String: String],
        withAuth: Bool = true,
        tag: String? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let generation = Session.shared.requestGeneration
        try validateGeneration(generation)
        var fields = form
        if withAuth {
            for (k, v) in Session.shared.authFields { fields[k] = v }
        }

        guard let url = URL(string: baseURL + path) else {
            throw ApiError.transport("URL 非法：\(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                     forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&req)
        req.httpBody = encodeForm(fields)

        let bodyPreview = fields
            .filter { !["loginCode", "password", "signature"].contains($0.key) }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "&")
        // 签名不进正文，但要记录长度和首 8 位，便于判断是否真的算出来了
        let sigInfo = fields["signature"].map { "signature(len=\($0.count), head=\($0.prefix(8)))" } ?? "signature=MISSING"
        let headerDump = (req.allHTTPHeaderFields ?? [:])
            .map { "\($0.key)=\($0.value)" }
            .filter { !$0.lowercased().hasPrefix("content-length") }
            .sorted()
            .joined(separator: " ")

        let started = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            try validateGeneration(generation)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            AppLog.shared.i(
                "HTTP \(code) POST \(path) (\(ms)ms)\(tag.map { " [\($0)]" } ?? "")",
                "headers: \(headerDump)\n\(sigInfo)\nreq: \(bodyPreview)\nresp: \(text.prefix(600))"
            )
            // 对照 Android：Retrofit 遇到 401/403 抛 HttpException，上层据此判挤号。
            // 这里不抛的话，挤号只能靠业务文案识别，漏判率更高。
            if code == 401 || code == 403 {
                throw ApiError.unauthorized(status: code)
            }
            guard (200..<300).contains(code) else { throw ApiError.http(status: code) }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ApiError {
            throw error
        } catch {
            try validateGeneration(generation)
            AppLog.shared.e("HTTP FAIL POST \(path)", "\(error.localizedDescription)")
            throw ApiError.transport(error.localizedDescription)
        }
    }

    /// GET（自动拼 auth，但跳过 verification 接口）
    static func get(
        _ path: String,
        query: [String: String] = [:],
        tag: String? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let generation = Session.shared.requestGeneration
        try validateGeneration(generation)
        guard var comps = URLComponents(string: baseURL + path) else {
            throw ApiError.transport("URL 非法：\(path)")
        }
        var items = comps.queryItems ?? []
        for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
        if Session.shared.isLoggedIn && !path.contains("verification") {
            for (k, v) in Session.shared.authQuery {
                items.append(URLQueryItem(name: k, value: v))
            }
        }
        comps.queryItems = items

        guard let url = comps.url else { throw ApiError.transport("URL 拼接失败") }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyCommonHeaders(&req)

        let started = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            try validateGeneration(generation)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            AppLog.shared.i(
                "HTTP \(code) GET \(path) (\(ms)ms)\(tag.map { " [\($0)]" } ?? "")",
                "resp: \(text.prefix(400))"
            )
            if code == 401 || code == 403 {
                throw ApiError.unauthorized(status: code)
            }
            guard (200..<300).contains(code) else { throw ApiError.http(status: code) }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ApiError {
            throw error
        } catch {
            try validateGeneration(generation)
            AppLog.shared.e("HTTP FAIL GET \(path)", "\(error.localizedDescription)")
            throw ApiError.transport(error.localizedDescription)
        }
    }

    // MARK: - 内部

    private static func validateGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        if let inherited = SessionWork.generation, inherited != generation { throw CancellationError() }
        guard generation == Session.shared.requestGeneration else { throw CancellationError() }
    }

    private static func applyCommonHeaders(_ req: inout URLRequest) {
        let pid = Session.shared.projectId
        if !pid.isEmpty && pid != "0" {
            req.setValue(pid, forHTTPHeaderField: "Config-Project")
            req.setValue(configKeys, forHTTPHeaderField: "Config-Keys")
        }
    }

    static func encodeForm(_ fields: [String: String]) -> Data {
        // 用 application/x-www-form-urlencoded 的规则：空格 → +，其余百分号编码
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        allowed.insert(charactersIn: "*")
        let body = fields.map { k, v -> String in
            let ek = (k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k).replacingOccurrences(of: "%20", with: "+")
            let ev = (v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v).replacingOccurrences(of: "%20", with: "+")
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    // MARK: - 业务响应

    /// 解析 `{ success, errorCode, errorMessage, data }`，`success == false` 时**抛错**。
    ///
    /// 只适用于「失败就该中断」的接口（登录、改密、领取使用码……）。
    /// 需要看 `errorCode` 的接口一律用 `decodeShell`，否则分支永远是死的（见那里的说明）。
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> APIResponse<T> {
        let resp = try decodeShell(type, from: data, path: path)
        guard resp.success else {
            throw ApiError.business(
                code: resp.errorCode ?? -1,
                message: resp.errorMessage ?? resp.msg ?? "请求失败"
            )
        }
        return resp
    }

    /// 只解外壳、**不因 `success == false` 抛错** —— 对照 Android 的 `SafeApi.parse`。
    ///
    /// ## 为什么必须有这个
    ///
    /// 服务端的业务语义大量藏在 `success=false` 里，而且**全是正常流程**：
    ///
    /// | errorCode | 含义 | 正确反应 |
    /// |---|---|---|
    /// | 306 | 设备不在线（4G 通道下发不到） | 问用户要不要改用蓝牙 |
    /// | 307 | 已有订单 / 已在关闭中 | 恢复订单 / 视为关阀成功 |
    /// | 206 / 209 | 蓝牙上传已受理 | 视为结算成功 |
    ///
    /// 用 `decode` 会把它们统统变成异常，调用方再写 `if errorCode == 306` 就**永远不成立**
    /// ——这正是「蓝牙表开了不阀、用户白等一次网络往返」的根因。
    static func decodeShell<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        path: String
    ) throws -> APIResponse<T> {
        do {
            return try JSONDecoder().decode(APIResponse<T>.self, from: data)
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            AppLog.shared.e("解析失败 \(path)", "\(error.localizedDescription)\n原文: \(text.prefix(300))")
            throw ApiError.transport("响应解析失败")
        }
    }
}
