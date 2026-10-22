import Foundation

/// 服务端统一响应外壳
struct APIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let errorCode: Int?
    let errorMessage: String?
    let msg: String?

    var displayMessage: String? { errorMessage ?? msg }
}

// MARK: - 登录

struct LoginData: Decodable {
    let userId: Int?
    let loginCode: String?
    let userAccount: UserAccount?
}

struct UserAccount: Decodable {
    let accountId: Int?
    let name: String?
    let projectId: Int?
    let accountRealMoney: Double?
}

// MARK: - 设备

/// `/device/info/mac` 的返回。
///
/// ⚠️ 字段一律可选：不同学校返回的字段集合不同；用非可选会让解析整体失败。
struct DeviceInfo: Decodable {
    let deviceId: Int?
    let deviceName: String?
    let deviceDesc: String?
    let macAddress: String?
    let realMac: String?
    let snCode: String?
    let bigTypeId: Int?
    let bigTypeName: String?
    let smallTypeId: Int?
    let smallTypeName: String?
    let projectId: Int?
    /// 服务端明确标记的「只能蓝牙控制」
    let isBle: Bool?
    let roomName: String?
    let buildingName: String?
    let floorName: String?

    /// 是否蓝牙表：服务端标记为真
    var needsBluetooth: Bool { isBle == true }

    /// 展示名（去掉学校前缀那类冗余）
    var displayName: String { deviceName ?? deviceDesc ?? snCode ?? "未知设备" }

    /// 用于蓝牙连接的地址
    ///
    /// ⚠️ `realMac` 优先（部分设备 `macAddress` 是虚拟的）。
    /// 本项目实测这批设备的 `realMac`/`macAddress` 与广播 MAC 一致。
    var connectMac: String {
        let raw = realMac?.isEmpty == false ? realMac! : (macAddress ?? snCode ?? "")
        return raw.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
    }
}

// MARK: - 蓝牙开阀

/// `/order/downRate/bluetooth/rateOrder` 的返回
struct BluetoothRateOrderData: Decodable {
    /// 要写进设备的费率包原文（**HEX 字符串**），必须原样交给 BLE 层
    let downData: String?
    /// 失败上报时要用的凭证，开阀成功时就要存下来
    let consumeDate: String?
    let orderNo: String?
    let preDeductMoney: Double?
    let preDeductMoneyStr: String?
}

// MARK: - 结算

/// `/order/upload/bluetooth/data` 的返回
struct BluetoothUploadData: Decodable {
    let upMoney: Double?
    let upMoneyStr: String?
    let orderNo: String?
    /// 写回设备用的加密数据（`clData`），需要 AES 解密后取 `-` 之后那段
    let clData: String?
    let consumeDate: String?
}

// MARK: - 已存在的订单

struct UsingOrderData: Decodable {
    let orderNo: String?
    let isOwner: Bool?
    let expireTimes: Int?
    let preDeductMoney: Double?
}
