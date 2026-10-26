import Foundation

enum LoginFeedback {
    static func message(_ error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "连接超时，请检查网络后重试"
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "网络连接失败，请检查网络设置"
            default: break
            }
        }
        let value = error.localizedDescription
        let lower = value.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") { return "连接超时，请检查网络后重试" }
        if ["offline", "internet connection", "resolve host", "network is unreachable", "connect to", "connection was lost"].contains(where: lower.contains) {
            return "网络连接失败，请检查网络设置"
        }
        return value
    }
}
