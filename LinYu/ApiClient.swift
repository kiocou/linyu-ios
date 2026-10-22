import Foundation

/// HTTP 层的错误
enum ApiError: LocalizedError {
    /// 业务错误（success=false），带服务端 errorCode
    case business(code: Int, message: String)
    /// 网络/解码层面
    case transport(String)
    /// 未登录
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .business(let code, let msg): return "\(msg)（\(code)）"
        case .transport(let msg): return msg
        case .notLoggedIn: return "未登录"
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

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    // MARK: - 请求

    /// POST form-urlencoded
    static func post(
        _ path: String,
        form: [String: String],
        withAuth: Bool = true,
        tag: String? = nil
    ) async throws -> Data {
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

        let started = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            AppLog.shared.i(
                "HTTP \(code) POST \(path) (\(ms)ms)\(tag.map { " [\($0)]" } ?? "")",
                "req: \(bodyPreview)\nresp: \(text.prefix(600))"
            )
            return data
        } catch {
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
        guard var comps = URLComponents(string: baseURL + path) else {
            throw ApiError.transport("URL 非法：\(path)")
        }
        var items = comps.queryItems ?? []
        for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
        if !path.contains("verification") {
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
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            AppLog.shared.i(
                "HTTP \(code) GET \(path) (\(ms)ms)\(tag.map { " [\(tag)]" } ?? "")",
                "resp: \(text.prefix(400))"
            )
            return data
        } catch {
            AppLog.shared.e("HTTP FAIL GET \(path)", "\(error.localizedDescription)")
            throw ApiError.transport(error.localizedDescription)
        }
    }

    // MARK: - 内部

    private static func applyCommonHeaders(_ req: inout URLRequest) {
        let pid = Session.shared.projectId
        if !pid.isEmpty && pid != "0" {
            req.setValue(pid, forHTTPHeaderField: "Config-Project")
            req.setValue(configKeys, forHTTPHeaderField: "Config-Keys")
        }
        req.setValue("android", forHTTPHeaderField: "phoneSystem")
    }

    private static func encodeForm(_ fields: [String: String]) -> Data {
        // 用 application/x-www-form-urlencoded 的规则：空格 → +，其余百分号编码
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        allowed.insert(charactersIn: "*")
        let body = fields.map { k, v -> String in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    // MARK: - 业务响应

    /// 解析 `{ success, errorCode, errorMessage, data }`
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> APIResponse<T> {
        do {
            let resp = try JSONDecoder().decode(APIResponse<T>.self, from: data)
            if !resp.success {
                throw ApiError.business(
                    code: resp.errorCode,
                    message: resp.errorMessage ?? resp.msg ?? "请求失败"
                )
            }
            return resp
        } catch let e as ApiError {
            throw e
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            AppLog.shared.e("解析失败 \(path)", "\(error.localizedDescription)\n原文: \(text.prefix(300))")
            throw ApiError.transport("响应解析失败")
        }
    }
}
