import Foundation
extension DeviceInfo { static func formatDeviceName(_ value: String) -> String { value } }

// 独立编译生产 ApiClient；URLProtocol 拦截全部请求，禁止访问真实账号和水控服务。
final class Session {
    static let shared = Session()
    var requestGeneration = UUID()
    var projectId = "test-school"
    var authFields: [String: String] { ["loginCode": "test-only"] }
    var authQuery: [String: String] { authFields }
}
final class AppLog {
    static let shared = AppLog()
    func i(_ text: String, _ detail: String?) {}
    func e(_ text: String, _ detail: String?) {}
}
final class MockProtocol: URLProtocol {
    static var status = 200
    static var rotateSession = false
    static var failNetwork = false
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if Self.rotateSession { Session.shared.requestGeneration = UUID() }
        if Self.failNetwork {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"success":true,"data":null}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct NetworkRegression {
    static func main() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        ApiClient.session = URLSession(configuration: config)
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        let methods: [(String, () async throws -> Data)] = [
            ("GET", { try await ApiClient.get("/mock") }),
            ("POST", { try await ApiClient.post("/mock", form: [:]) }),
            ("JSON", { try await ApiClient.postJSON("/mock", body: [:]) })
        ]
        for (name, request) in methods {
            for status in [401, 403] {
                MockProtocol.status = status
                do { _ = try await request(); check(false, "\(name) \(status)") }
                catch ApiError.unauthorized(let actual) { check(actual == status, "\(name)保留HTTP \(status)类型") }
                catch { check(false, "\(name)错误被包装: \(error)") }
            }
            MockProtocol.status = 200
            MockProtocol.rotateSession = true
            do { _ = try await request(); check(false, "\(name)过期响应") }
            catch is CancellationError { check(true, "\(name)拒绝旧会话成功响应") }
            catch { check(false, "\(name)过期错误类型") }
            MockProtocol.failNetwork = true
            do { _ = try await request(); check(false, "\(name)过期网络错误") }
            catch is CancellationError { check(true, "\(name)旧会话网络错误也按取消处理") }
            catch { check(false, "\(name)过期网络错误类型") }
            MockProtocol.rotateSession = false
            do { _ = try await request(); check(false, "\(name)断网") }
            catch ApiError.transport { check(true, "\(name)断网不当作登录失效") }
            catch { check(false, "\(name)断网错误类型") }
            MockProtocol.failNetwork = false
        }
        let before = MockProtocol.requests
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await ApiClient.get("/mock"); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let didCancel = await cancelled.value
        check(didCancel && MockProtocol.requests == before, "取消任务不发起网络请求")
        if failures > 0 { fatalError("网络回归失败 \(failures)") }
    }
}
