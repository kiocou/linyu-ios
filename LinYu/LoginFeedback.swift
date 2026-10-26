import Foundation

enum LoginFeedback {
    static func message(_ error: Error, fallback: String = "网络异常，请重试") -> String {
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "连接超时，请重试"
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "网络异常，请重试"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "安全连接失败，请重试"
            case .cancelled: return "操作已取消"
            default: return "网络异常，请重试"
            }
        }
        let value = error.localizedDescription
        let lower = value.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") { return "连接超时，请重试" }
        if ["offline", "internet connection", "resolve host", "network is unreachable", "connect to", "connection was lost"].contains(where: lower.contains) {
            return "网络异常，请重试"
        }
        return chineseMessage(value, fallback: fallback)
    }

    /// 保留中文业务原因；系统英文错误只写日志，不直接展示给用户。
    static func chineseMessage(_ value: String, fallback: String = "请求失败，请稍后重试") -> String {
        value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } ? value : fallback
    }
}
