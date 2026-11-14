import Foundation

enum LoginFeedback {
    static func message(_ error: Error, fallback: String = "网络连接失败，请检查网络") -> String {
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "连接超时，请重试"
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "网络连接失败，请检查网络"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "安全连接失败，请重试"
            case .cancelled: return "操作已取消"
            default: return "网络连接失败，请检查网络"
            }
        }
        let value = error.localizedDescription
        let lower = value.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") { return "连接超时，请重试" }
        if ["offline", "internet connection", "resolve host", "network is unreachable", "connect to", "connection was lost"].contains(where: lower.contains) {
            return "网络连接失败，请检查网络"
        }
        return chineseMessage(value, fallback: fallback)
    }

    /// 仅用于错误展示，不改变原始响应和业务判断；排除中英混合的异常详情。
    static func chineseMessage(_ value: String, fallback: String = "请求失败，请稍后重试") -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "1天只能领取一次使用码" { return "每天只能领取一次使用码" }
        let lower = text.lowercased()
        if ["timeout", "timed out"].contains(where: lower.contains) { return "连接超时，请重试" }
        if ["unable to resolve host", "no address associated", "network is unreachable",
            "offline", "internet connection", "failed to connect", "connection was lost"].contains(where: lower.contains) {
            return "网络连接失败，请检查网络"
        }
        let hasChinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let hasLatin = text.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        return hasChinese && !hasLatin && text.count <= 120 && !text.contains("\n") && !text.contains("\r") ? text : fallback
    }
}
