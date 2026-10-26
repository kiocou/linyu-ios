import Foundation

/// 与 Android BleShowerController 保持相同的请求值；签名和发送字段使用同一大小写约定。
enum BleRequestFields {
    static func rate(device: DeviceInfo, deviceId: String, mac: String, macType: String,
                     state: DeviceState, xfModel: String, signature: String) -> [String: String] {
        ["deviceId": deviceId, "macAddress": mac, "macType": macType,
         "bigTypeId": String(device.bigTypeId ?? 0), "smallTypeId": String(device.smallTypeId ?? 0),
         "protocolType": state.protocolType, "randomNumber": state.randomNumber.lowercased(),
         "xfModel": xfModel, "signature": signature]
    }
    static func upload(protocolType: String, randomNumber: String, xfData: String, signature: String) -> [String: String] {
        ["protocolType": protocolType, "randomNumber": randomNumber.lowercased(),
         "xfData": xfData.lowercased(), "signature": signature]
    }
}
