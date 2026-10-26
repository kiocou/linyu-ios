import Foundation

enum LogRedactor {
    static func mask(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"(?<!\d)(1[3-9]\d)\d{4}(\d{4})(?!\d)"#,
            with: "$1****$2", options: .regularExpression)
        for key in ["loginCode", "password", "oldPassword", "useCode", "code", "smsCode", "signature", "token", "sign"] {
            out = out.replacingOccurrences(of: "(\(key)=)([^&\\s\"]+)", with: "$1***", options: .regularExpression)
            out = out.replacingOccurrences(of: "(\"\(key)\"\\s*:\\s*\")([^\"]*)(\")", with: "$1***$3", options: .regularExpression)
        }
        return out
    }
}
