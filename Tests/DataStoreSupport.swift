import Foundation

enum ApiError: Error { case transport(String); case unauthorized(status: Int) }
struct EmptyData: Decodable {}
enum Prefs { static var campusBalance = ""; static var walletBalance = "" }
enum BalanceEstimator { static func billTimeMs(_ value: String) -> Double { 0 } }
extension DeviceInfo { static func formatDeviceName(_ value: String) -> String { value } }
final class AppLog {
    static let shared = AppLog()
    func i(_ text: String) {}
    func w(_ text: String) {}
}
enum ApiClient {
    static var failBills = false
    static var emptyBills = false
    static var failingMonth: String?
    static var delay: UInt64 = 0
    static var activeRequests = 0
    static func get(_ path: String, query: [String: String] = [:], tag: String? = nil) async throws -> Data {
        activeRequests += 1
        defer { activeRequests -= 1 }
        try Task.checkCancellation()
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if path.contains("bill/list") {
            if failBills { throw URLError(.notConnectedToInternet) }
            let month = query["month"] ?? ""
            if month == failingMonth { throw URLError(.notConnectedToInternet) }
            let data: String = emptyBills ? "[]" : "[{\"consumeBillDTO\":{\"orderId\":\"\(month)\",\"consumeMoney\":\"2.00\"}}]"
            return Data("{\"success\":true,\"data\":\(data)}".utf8)
        }
        return Data("{\"success\":true,\"data\":null}".utf8)
    }
    static func post(_ path: String, form: [String: String], tag: String? = nil) async throws -> Data {
        Data("{\"success\":true,\"data\":null}".utf8)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> APIResponse<T> {
        try JSONDecoder().decode(APIResponse<T>.self, from: data)
    }
    static func decodeShell<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> APIResponse<T> {
        try JSONDecoder().decode(APIResponse<T>.self, from: data)
    }
}
