import Foundation
import CryptoKit

/// 蓝牙水表的**请求签名**。逐行对照 Android 的 `KlcxkjSigner.kt`。
///
/// ## 算法
///
/// ```
/// 内层 = MD5( raw + "&key=" + sessionKey )
/// 签名 = MD5( 内层 + "&key=sign-kailu-855c74a88b8b494187c99b08b8c9a744" )
/// ```
///
/// - `raw` 是按 key 升序拼好的键值串（见 `BleSign.raw`）
/// - `sessionKey` 就是服务端下发的 `loginCode`
/// - 外层那串是**固定常量**（自带 `&key=` 前缀，不是笔误）
///
/// ⚠️ 这是嵌套 MD5，且 `&key=` 出现两次。Android 端逆向时穷举 18 万种拼接组合
/// 都没算出来，最后靠社区从 native 里挖出结构。所以**不要"简化"它**。
enum Signer {

    /// 外层固定密钥（含 `&key=` 前缀）
    private static let outerKey = "&key=sign-kailu-855c74a88b8b494187c99b08b8c9a744"

    /// 计算签名
    /// - Parameters:
    ///   - sessionKey: 会话密钥（`loginCode`）
    ///   - raw: 按 key 升序拼好的键值串
    static func signParams(sessionKey: String, raw: String) -> String? {
        guard !sessionKey.isEmpty else {
            AppLog.shared.w("签名被拒：sessionKey 为空")
            return nil
        }
        let inner = md5Hex(raw + "&key=" + sessionKey)
        return md5Hex(inner + outerKey)
    }

    /// MD5 → 32 位**小写** hex
    static func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 蓝牙通道的**签名构造**。对照 Android 的 `BleSignBuilder.kt`。
///
/// ## 各接口的签名字段**不一样**（协议规定，写错就是签名无效）
///
/// | 接口 | 参与签名的字段 |
/// |---|---|
/// | `bluetoothRateOrder` | telephone、deviceId、xfModel、randomNumber |
/// | `bluetoothUploadData` | loginCode、telephone、xfData |
/// | `bluetoothFailOrder` | consumeDate、loginCode、telephone |
enum BleSign {

    /// key 升序拼成 `key1value1key2value2…`
    ///
    /// ⚠️ value 为 nil 时**整个字段跳过**（连 key 一起），不是当空串
    static func raw(_ params: [String: String?]) -> String {
        params.keys.sorted().map { k in
            guard let v = params[k], let vv = v else { return "" }
            return k + vv
        }.joined()
    }

    /// `macType` 参数：两个字节小写 hex 拼接
    static func macType(type: Int, a1: Int) -> String {
        String(format: "%02x%02x", type & 0xFF, a1 & 0xFF)
    }

    /// 下费率（开阀第一步）
    static func signRateOrder(
        loginCode: String,
        telephone: String,
        deviceId: String,
        xfModel: String,
        randomNumber: String
    ) -> String? {
        Signer.signParams(
            sessionKey: loginCode,
            raw: raw([
                "telephone": telephone,
                "deviceId": deviceId,
                "xfModel": xfModel,
                "randomNumber": randomNumber.lowercased()
            ])
        )
    }

    /// 上传消费数据（结算）
    ///
    /// ⚠️ `xfData` 参与签名和上传字段都必须是**小写**。
    /// Android 端踩过：签名用小写、上传用大写 → 服务端重算对不上 → 170。
    static func signUpload(
        loginCode: String,
        telephone: String,
        xfData: String
    ) -> String? {
        Signer.signParams(
            sessionKey: loginCode,
            raw: raw([
                "loginCode": loginCode,
                "telephone": telephone,
                "xfData": xfData.lowercased()
            ])
        )
    }

    /// 上报失败订单
    static func signFail(
        loginCode: String,
        telephone: String,
        consumeDate: String
    ) -> String? {
        Signer.signParams(
            sessionKey: loginCode,
            raw: raw([
                "consumeDate": consumeDate,
                "loginCode": loginCode,
                "telephone": telephone
            ])
        )
    }
}
