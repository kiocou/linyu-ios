import Foundation
import CommonCrypto

/// 凯路设备域 AES 解密——对照 Android 的 `KlcxkjCrypto.kt`。
///
/// ## AES 参数（逆向确认）
///
/// - **AES-128-ECB**，密钥 `"20210118klcx@002"`，**无填充**（NoPadding）
/// - 密文是标准 Base64
/// - 解密后手动去 PKCS#7，再按 C 字符串截断（到第一个 0x00）
///
/// ## 为什么必须有
///
/// 结算写回（`0x86`）的数据来自服务端返回的 `clData` 解密结果。
/// 缺了它，设备侧离线记录清不掉，设备会停在 `state=3`，
/// **下次开阀报「设备正在使用中」** —— Android 端早期把它当成可选步骤，
/// 结果设备卡死再也没法开阀。
enum KlcxkjCrypto {

    private static let aesKey = "20210118klcx@002"

    /// 解密设备域数据。
    /// - Returns: 明文；失败返回 nil。
    ///   明文格式是 `<前缀>-<dataHex>`，取 `-` 之后那段才是要写回设备的 `0x86` 数据。
    static func decryptByAes(_ cipher: String) -> String? {
        guard !cipher.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let decoded = base64Decode(cipher) else { return nil }

        // 长度不是 16 的倍数时，按 native 的行为直接当作明文
        let decrypted: Data
        if decoded.count % 16 == 0 && !decoded.isEmpty {
            decrypted = aesEcbDecrypt(decoded) ?? decoded
        } else {
            decrypted = decoded
        }

        let text = stripPaddingToText(decrypted)
        return text.isEmpty ? nil : text
    }

    // MARK: - AES

    private static func aesEcbDecrypt(_ data: Data) -> Data? {
        let keyData = Data(aesKey.utf8)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        // ⚠️ 必须在 withUnsafeMutableBytes 之前取出容量：
        // 在闭包里访问 out.count 会构成对 out 的「重叠独占访问」，Swift 直接报错
        let outCapacity = out.count
        var outLength = 0

        let status = out.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            guard let outPtr = outBytes.bindMemory(to: UInt8.self).baseAddress else {
                return CCCryptorStatus(kCCMemoryFailure)
            }
            return data.withUnsafeBytes { dataBytes -> CCCryptorStatus in
                guard let dataPtr = dataBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return CCCryptorStatus(kCCMemoryFailure)
                }
                return keyData.withUnsafeBytes { keyBytes -> CCCryptorStatus in
                    guard let keyPtr = keyBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return CCCryptorStatus(kCCMemoryFailure)
                    }
                    return CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0),                 // 无填充
                        keyPtr, keyData.count,
                        nil,                          // ECB 不需要 IV
                        dataPtr, data.count,
                        outPtr, outCapacity,
                        &outLength
                    )
                }
            }
        }

        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return out.prefix(outLength)
    }

    // MARK: - 去填充

    /// 对齐 native `decryptByAES` 语义：
    /// - 末字节 last 在 1..n 且末尾 last 字节都等于 last → 去掉（PKCS#7）
    /// - 不满足 → 返回空串；last == 0 或 > n 视为无填充
    /// - 最后按 C 字符串截断（到第一个 0x00）
    private static func stripPaddingToText(_ data: Data) -> String {
        let n = data.count
        guard n > 0 else { return "" }

        var effective = data
        let last = Int(data[n - 1])
        if last >= 1 && last <= n {
            let start = n - last
            for i in stride(from: n - 1, through: start, by: -1) {
                if Int(data[i]) != last { return "" }
            }
            effective = data.prefix(n - last)
        }

        let zeroIndex = effective.firstIndex(of: 0) ?? effective.count
        let bytes = effective.prefix(zeroIndex)
        return String(data: Data(bytes), encoding: .utf8) ?? ""
    }

    // MARK: - Base64（对齐 native：遇 '=' 或非法字符停止）

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    private static func base64Decode(_ input: String) -> Data? {
        var out = Data()
        var quad = [Int](repeating: 0, count: 4)
        var cnt = 0

        for ch in input {
            if ch == "=" || !alphabet.contains(ch) { break }
            guard let v = alphabet.firstIndex(of: ch) else { continue }
            quad[cnt] = v
            cnt += 1
            if cnt == 4 {
                out.append(UInt8(((quad[0] << 2) | ((quad[1] & 0x30) >> 4)) & 0xFF))
                out.append(UInt8((((quad[1] & 0x0F) << 4) | ((quad[2] & 0x3C) >> 2)) & 0xFF))
                out.append(UInt8((((quad[2] & 0x03) << 6) | quad[3]) & 0xFF))
                cnt = 0
            }
        }
        if cnt == 2 {
            out.append(UInt8(((quad[0] << 2) | ((quad[1] & 0x30) >> 4)) & 0xFF))
        } else if cnt == 3 {
            out.append(UInt8(((quad[0] << 2) | ((quad[1] & 0x30) >> 4)) & 0xFF))
            out.append(UInt8((((quad[1] & 0x0F) << 4) | ((quad[2] & 0x3C) >> 2)) & 0xFF))
        }
        return out.isEmpty ? nil : out
    }
}
