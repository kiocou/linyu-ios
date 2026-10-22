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
    // 故意不解析 accountRealMoney：服务端可能给数字也可能给字符串
    // （"0.0"），声明成任何一种都可能在换校后解码失败，而本项目用不到它。
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

    // displayName / typeEmoji / statusText 等展示逻辑在 DeviceInfoDisplay.swift
    // （那边是逐条对照 Android DeviceModels.kt 的完整实现，别在这里重复）

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
///
/// ⚠️ 服务端这些数值字段**全是字符串**（实测 projectId=905）：
/// ```json
/// "preDeductMoney":"0.0", "preDeductMoneySend":"5.0", "realMoney":"0.0"
/// ```
/// 声明成 `Double` 会让整个响应解码失败（`The data couldn't be read...`），
/// 表现为「解析失败 bluetoothRateOrder」，开阀直接中断。
struct BluetoothRateOrderData: Decodable {
    /// 要写进设备的费率包原文（**HEX 字符串**），必须原样交给 BLE 层
    let downData: String?
    /// 失败上报时要用的凭证，开阀成功时就要存下来
    let consumeDate: String?
    /// ⚠️ 蓝牙表这条通道可能返回 null —— 结算用 consumeDate + xfData，不依赖它
    let orderNo: String?
    let preDeductMoney: String?
    let preDeductMoneySend: String?
    let realMoney: String?
    let rate: Int?
    let minTime: Int?
    let minMoney: Int?
    let autoDisConTime: Int?
    let chargeMethod: Int?
    let minChargeUnit: Int?

    /// 展示用：预扣金额（元）
    var preDeductYuan: Double? {
        Self.yuan(preDeductMoney) ?? Self.yuan(preDeductMoneySend)
    }

    static func yuan(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        return Double(s)
    }
}

// MARK: - 结算

/// `/order/upload/bluetooth/data` 的返回
struct BluetoothUploadData: Decodable {
    /// ⚠️ 同样是字符串（如 "0.24"），不能声明成 Double
    let upMoney: String?
    let upMoneyStr: String?
    let orderNo: String?
    /// 写回设备用的加密数据（`clData`），需要 AES 解密后取 `-` 之后那段
    let clData: String?
    let consumeDate: String?

    /// 展示用：本次消费（元）
    var upMoneyYuan: Double? {
        guard let s = upMoney ?? upMoneyStr, !s.isEmpty else { return nil }
        return Double(s)
    }
}

// MARK: - 已存在的订单

struct UsingOrderData: Decodable {
    let orderNo: String?
    let isOwner: Bool?
    let expireTimes: Int?
    /// ⚠️ 同样是字符串形式
    let preDeductMoney: String?
}

// MARK: - 钱包 / 账单

struct WalletData: Decodable {
    let projectId: Int?
    let accountId: Int?
    /// ⚠️ 都是字符串（实测 "55.460"），不能声明成 Double
    let accountRealMoney: String?
    let accountGivenMoney: String?
    let money: String?

    var realYuan: Double? { accountRealMoney.flatMap(Double.init) }
    var moneyYuan: Double? { money.flatMap(Double.init) }
}

/// `/settlement/campus/userInfo`（一卡通余额）
struct CampusUserInfo: Decodable {
    let studentNumber: String?
    let studentName: String?
    /// 字符串（如 "16.76"）
    let amount: String?
    /// 1 = 已签约免密支付
    let signStatus: Int?

    var yuan: Double? { amount.flatMap(Double.init) }
}

/// `/order/query/account/bill/list` 的一项 —— 外面套一层 `consumeBillDTO`
struct BillItem: Decodable {
    let consumeBillDTO: BillDTO?
}

struct BillDTO: Decodable, Identifiable {
    /// 账单**序号**（7 位），和 orderNo 不是一回事
    let orderId: String?
    let consumeDate: String?
    let consumeMoney: String?
    let description: String?
    /// 下单时返回的 20 位 orderNo（关阀用）
    let orderNo: String?
    let preDeductMoney: String?
    let deviceSnCode: String?

    var id: String { orderId ?? consumeDate ?? UUID().uuidString }

    var yuan: Double? { consumeMoney.flatMap(Double.init) }

    /// 设备名（`description` 形如 `项目名:热水表-xxx`）
    var deviceNamePart: String {
        let raw = description ?? ""
        let after = raw.contains(":") ? String(raw.split(separator: ":", maxSplits: 1).last ?? "") : raw
        return after.isEmpty ? raw : DeviceInfo.formatDeviceName(after)
    }

    var isDrinkingWaterBill: Bool {
        let d = description ?? ""
        return d.contains("饮水") || d.contains("直饮") || d.contains("冷水")
    }

    var deviceTypeLabel: String {
        if isDrinkingWaterBill { return "饮水机" }
        let n = deviceNamePart
        return n.hasPrefix("洗手台") ? "洗手台热水器" : "卫生间热水器"
    }

    var deviceEmoji: String {
        if isDrinkingWaterBill { return "🚰" }
        return (deviceNamePart.hasPrefix("洗手台")) ? "🪥" : "🚿"
    }
}

/// `/account/info`
struct AccountInfo: Decodable {
    let name: String?
    let idCardNumber: String?
    let telephone: String?
    let genderName: String?
    let cardStatus: Int?
    let cardStatusName: String?
    let gradeName: String?
    let className: String?
}

/// `/project/info/triple`
struct ProjectInfo: Decodable {
    let projectId: Int?
    let projectName: String?
    let serverPhone: String?
}
