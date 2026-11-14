import Foundation

enum LogRedactor {
    static func mask(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"(?<!\d)(1[3-9]\d)\d{4}(\d{4})(?!\d)"#,
            with: "$1****$2", options: .regularExpression)
        // ⚠️ 不要再把裸 "code" 加进来：它命中的是 `errorCode=306` / `CONNACK code=5`
        // 这类**故障码**，抹掉之后日志里就只剩「code=***」，现场无法定位
        // （2026-11-14 那次 MQTT 拒绝就是这样被吃掉的）。验证码只脱 smsCode/loginCode/useCode。
        for key in ["loginCode", "password", "oldPassword", "useCode", "smsCode", "signature", "token", "sign"] {
            out = out.replacingOccurrences(of: "(\(key)=)([^&\\s\"]+)", with: "$1***", options: .regularExpression)
            out = out.replacingOccurrences(of: "(\"\(key)\"\\s*:\\s*\")([^\"]*)(\")", with: "$1***$3", options: .regularExpression)
        }
        return out
    }
}
