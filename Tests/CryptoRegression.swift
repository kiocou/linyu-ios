import Foundation

/// `clData` 写回数据的解密回归。
///
/// 这条向量锁的是 **AES 模式**：CommonCrypto 的 `CCOptions(0)` 是 CBC（IV=nil 即全零 IV），
/// 只有第一块解得出原文、后面全部错位，末字节再被 PKCS#7 校验判成非法
/// → `decryptByAes` 返回 nil → `0x86` 永远发不出去 → 设备停在 state=3/6
/// → 每次开阀都走「补结算」再失败，App 里表现为
/// 「账单已结清，设备清理未确认」的死循环（2026-11-14 22:54 真机）。
@main struct CryptoRegression {
    static func main() {
        var failures = 0
        func check(_ result: Bool, _ message: String) {
            print("\(result ? "PASS" : "FAIL"): \(message)")
            if !result { failures += 1 }
        }

        // 真机 /order/upload/bluetooth/data 实际返回的 clData
        let clData = "IEwHAUC2FByBRRsxfKDEfhLTkfwG0JtxyliXBfBXSGjOz31MLYUAQDd5b4c2n3nE5kaSF5sB3d5iToneuYTV7MG1MtEdK3F1Sx+df7bFZmc="
        // 明文 = 前缀 + "-" + HEX(写回载荷)，尾部 PKCS#7 填充 02 02
        let expected = "1794668064542-2611142254170000035b0000012c000027a7000000020000000000BB4EC2CE29"

        let plain = KlcxkjCrypto.decryptByAes(clData)
        check(plain == expected, "AES-128-ECB 解出完整明文（模式必须是 ECB 而不是 CBC）")

        if let plain {
            let hexPart = plain.contains("-")
                ? String(plain.split(separator: "-", maxSplits: 1).last ?? "") : plain
            if let bytes = BleFrame.fromHex(hexPart) {
                check(!bytes.isEmpty && bytes.count >= 16, "写回载荷可解析且长度合理（\(bytes.count)B）")
            } else {
                check(false, "写回载荷 HEX 无法解析")
            }
        } else {
            check(false, "clData 解密返回 nil")
        }

        check(KlcxkjCrypto.decryptByAes("") == nil, "空串不产生写回数据")
        check(KlcxkjCrypto.decryptByAes("not-base64!!") == nil, "非法输入不产生写回数据")
        check(KlcxkjCrypto.decryptByAes("AAAA") == nil, "长度非法时不误判为有效明文")

        if failures > 0 {
            print("FAILURES: \(failures)")
            exit(1)
        }
        print("CryptoRegression: all checks passed")
    }
}
