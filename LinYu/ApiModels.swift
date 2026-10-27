import Foundation

/// 服务端统一响应外壳
struct APIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let errorCode: Int?
    let errorMessage: String?
    let msg: String?

    var displayMessage: String? { (errorMessage ?? msg).map { LoginFeedback.chineseMessage($0) } }
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
    /// 预扣金额（元）。服务端有的学校给数字、有的给字符串，用 AnyNumber 兜住
    let withholdMoney: AnyNumber?
    /// 通信类型 id（服务端字段 `communicationTypeId`），仅作诊断，不参与判定
    let communicationTypeId: Int?

    /// 预扣金额（元）
    var withholdYuan: Double? { withholdMoney?.value }

    /// 是否「只能靠手机蓝牙直连控制」的水表。
    ///
    /// ⚠️ **只认服务端标记 `isBle`**，不能用 `smallTypeId == 1` 兜底——
    /// Android 的 DeviceModels.kt 里明确写了：两所学校的 4G 表 `smallTypeId` 也都是 1，
    /// 拿它判断会把正常的云端表拦下来（表现为「这台设备打不开」）。
    /// 服务端不返回 `isBle` 时只能当普通表试一次，失败后再问用户要不要改用蓝牙。
    var needsBluetoothControl: Bool { isBle == true }

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
    /// ⚠️ 单位是**厘**（1 元 = 1000 厘）。
    ///
    /// Android `BleModels.kt` 里 `upMoney` 声明成 `Int?`，展示前统一过
    /// `MoneyFormat.milliToYuan`（`WidgetBleService.kt:231` 有注释：
    /// 「服务端金额单位是厘，换算成元再交给通知」）。
    /// 直接当元用会**静默放大 1000 倍**。
    ///
    /// 另外服务端在不同学校用过 `upMoney` / `consumeMoney` 两个名字，两个都收。
    let upMoney: AnyNumber?
    let consumeMoney: AnyNumber?
    let orderNo: String?
    /// 写回设备用的加密数据（`clData`），需要 AES 解密后取 `-` 之后那段
    let clData: String?
    let consumeDate: String?

    /// 本次消费（**元**）
    var upMoneyYuan: Double? {
        (upMoney?.value ?? consumeMoney?.value).map { $0 / 1000.0 }
    }

    /// 逐字段容错解码。
    ///
    /// ⚠️ **不能依赖合成的 Decodable**：实测（projectId=859，`C47F0E6B1704`）
    /// 服务端明明返回了 `clData`，合成解码却让**所有字段都变成 nil**，
    /// 于是上层打印「服务端未返回 clData」，`0x86` 一次都没发出去，
    /// 设备永远停在 `state=3`。
    ///
    /// 这里每个字段单独 `decodeIfPresent` 并吞掉该字段的异常：
    /// 一个字段类型不符，不影响其余字段（尤其是 `clData`）。
    ///
    /// ⚠️ 本文件同时被回归测试编译（测试里没有 `AppLog`），
    /// 所以**不要在这里调用日志**：失败字段名收集到 `decodeIssues`，由调用方记录。
    private enum CodingKeys: String, CodingKey {
        case upMoney, consumeMoney, orderNo, clData, consumeDate
    }

    /// 解码时出问题的字段（字段名 → 原因），供调用方写日志
    let decodeIssues: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var issues: [String] = []

        /// 单字段容错取值：该字段异常时返回 nil，不拖垮其余字段
        func tolerant<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            do {
                return try c.decodeIfPresent(type, forKey: key)
            } catch {
                issues.append("\(key.rawValue)：\(error.localizedDescription)")
                return nil
            }
        }

        upMoney = tolerant(.upMoney, AnyNumber.self)
        consumeMoney = tolerant(.consumeMoney, AnyNumber.self)
        orderNo = tolerant(.orderNo, String.self)
        clData = tolerant(.clData, String.self)
        consumeDate = tolerant(.consumeDate, String.self)
        decodeIssues = issues
    }
}

// MARK: - 已存在的订单

struct UsingOrderData: Decodable {
    let orderNo: String?
    let isOwner: Bool?
    let expireTimes: Int?
    /// ⚠️ 实测（2026-10-22 projectId=905）这个字段返回的是**数字** `0`，
    /// 声明成 String 会让整个响应解码失败 —— 日志里表现为
    /// 「解析失败 queryUsing」，于是关阀后的确认永远拿不到结果。
    let preDeductMoney: AnyNumber?
}

// MARK: - 钱包 / 账单

struct WalletData: Decodable {
    let projectId: Int?
    let accountId: Int?
    /// ⚠️ 三个字段**类型不一样**（实测 projectId=905）：
    /// `accountRealMoney` / `accountGivenMoney` 是**数字** `0`，
    /// `money` 是**字符串** `"0.000"`。统一声明成 String 会让整个响应解码失败
    /// （日志里就是「解析失败 /account/wallet」，钱包余额永远读不到）。
    let accountRealMoney: AnyNumber?
    let accountGivenMoney: AnyNumber?
    let money: AnyNumber?

    var moneyYuan: Double? { money?.value }
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

struct BillDTO: Codable, Identifiable {
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

    /// 冒号之后的**原始**设备名。
    ///
    /// ⚠️ 不能过 `formatDeviceName`：那条规则会把 `洗手台54-` 前缀剥掉、
    /// 还会把结尾的「洗手台」换成「房」。用它判断设备类型的话，
    /// 洗手台账单会被判成「卫生间热水器」（实测反馈）。
    /// Android 的 `BillDTO.deviceTypeLabel` 也是直接用 `substringAfter(":")`。
    var rawNamePart: String {
        let raw = description ?? ""
        guard let r = raw.range(of: ":") else { return raw }
        return String(raw[r.upperBound...])
    }

    /// 展示用的设备名（过一遍格式化：去掉「热水表-」「洗手台54-」这类前缀）
    var displayNamePart: String { DeviceInfo.formatDeviceName(rawNamePart) }

    /// 是否饮水机账单（对照 Android：对**完整 description** 判，不是截取后的名字）
    var isDrinkingWaterBill: Bool {
        let d = description ?? ""
        return d.contains("饮水") || d.contains("直饮") || d.contains("冷水")
    }

    /// 设备类型标签：饮水机 / 洗手台热水器 / 卫生间热水器
    var deviceTypeLabel: String {
        let d = description ?? ""
        if isDrinkingWaterBill { return "饮水机" }
        // ⚠️ 除了判截取后的前缀，还要对**完整 description** 再判一次——
        // 项目名那半边也可能带「洗手台」
        if rawNamePart.hasPrefix("洗手台") || d.contains("洗手台") { return "洗手台热水器" }
        return "卫生间热水器"
    }

    /// 设备 emoji：饮水机 🚰 / 洗手台 🪥 / 热水器 🚿
    var deviceEmoji: String {
        if isDrinkingWaterBill { return "🚰" }
        return (description ?? "").contains("洗手台") ? "🪥" : "🚿"
    }
}

/// `/order/weixinScorePay/unPay/queryBill` 的一项 —— 俗称「残留账单」。
///
/// ⚠️ 这是**扁平结构**（不像账单列表套一层 `consumeBillDTO`），
/// 而且按 `consumeDate` 定位（不是 orderNo）—— 代扣接口也是拿它扣的。
struct UnpaidBill: Decodable, Identifiable {
    let orderId: String?
    let orderNo: String?
    let consumeDate: String?
    /// ⚠️ **字符串**、单位是元（和账单列表一致，和 consumeOrder/result 那个厘不同）
    let consumeMoney: String?
    let description: String?

    var id: String { orderId ?? consumeDate ?? orderNo ?? UUID().uuidString }
    var yuan: Double? { consumeMoney.flatMap(Double.init) }

    /// 设备名：`项目名:设备名` 里冒号之后那段，再套一遍格式化
    var displayNamePart: String {
        let raw = description ?? ""
        guard let r = raw.range(of: ":") else { return raw }
        return DeviceInfo.formatDeviceName(String(raw[r.upperBound...]))
    }
}

/// `/account/info`
struct AccountInfo: Codable {
    var name: String?
    var idCardNumber: String?
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


// MARK: - 宽松数字

/// 服务端数字字段有的给数字、有的给字符串（`\"preDeductMoney\":\"5.0\"`）。
///
/// 直接声明成 `Double` 会因类型不符导致**整个响应**解码失败 ——
/// 这在 `bluetoothRateOrder` 上真机踩过（表现为「解析失败 bluetoothRateOrder」，
/// 开阀第二步就断了）。包一层之后三种形式都能读，读不出来算 nil。
struct AnyNumber: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // 显式 null 直接按「没有值」处理：singleValueContainer 在 null 上解码会抛错，
        // 而这个结构体到处以可选字段出现，抛出去会拖垮整块 data。
        if c.decodeNil() { value = nil; return }
        if let d = try? c.decode(Double.self) { value = d; return }
        if let i = try? c.decode(Int.self) { value = Double(i); return }
        if let s = try? c.decode(String.self) { value = Double(s); return }
        value = nil
    }

    init(_ v: Double?) { value = v }
}

// MARK: - 云端（4G）通道

/// `/order/tcpDevice/downRate/rateOrder` 的返回
struct DownRateData: Decodable {
    let autoDisConTime: Int?
    let orderNo: String?
    let consumeDate: String?
    let state: Int?
    let result: Int?
    let preDeductMoney: AnyNumber?
    let rate: AnyNumber?

    var preDeductYuan: Double? { preDeductMoney?.value }
}

/// `/order/tcpDevice/query/downRateResult`
struct DownRateResultData: Decodable {
    let orderNo: String?
    let autoDisConTime: Int?
    let state: Int?
    let result: Int?
    let snCode: String?
    let preDeductMoney: AnyNumber?

    /// 开阀成功判据（对照 Android）：`state == 0 || result == 0 || orderNo != nil`
    var looksOpened: Bool { state == 0 || result == 0 || orderNo != nil }
}

/// `/order/consumeOrder/result/query`
///
/// ⚠️ 这个接口的 `consumeMoney` 单位是**厘**（1 元 = 1000 厘），
/// 和账单列表里同名字段的单位差 1000 倍。忘了换算不是报错，而是**静默错 1000 倍**：
/// 用了 0.04 元，通知上写成「消费 ¥40.00」。
///
/// 实测证据（Android 端 09-18 两笔订单，用 dealDate 对齐）：
/// 本接口 `40` ↔ 账单列表 `"0.04"`；本接口 `80` ↔ 账单列表 `"0.08"`。
struct ConsumeResultData: Decodable {
    let orderNo: String?
    /// 单位：**厘**
    let consumeMoney: AnyNumber?
    let consumeDate: String?

    /// 换算成元
    var yuan: Double? { consumeMoney?.value.map { $0 / 1000.0 } }
}


// MARK: - 使用码

/// `GET /account/useCode/new`
///
/// ⚠️ 字段一律可空：**没领过码时服务端真的返回 `"useCode": null`**。
/// 写成非可选会让整个响应解码失败，界面就永远停在「加载中」。
struct GeneratedUseCode: Decodable {
    let useCode: String?
    let remainTimes: Int?
}

struct UseCodeData: Decodable {
    let useCode: String?
    /// 1 = 开启，0 = 关闭
    var useCodeStatus: Int?
    /// 手机号后三位（和 useCode 末三位相同）
    let useCodeRandom: String?
    let useCodeStartTime: String?
    /// 今天还能不能重新领取：1 = 能，0 = 不能
    let resetAvailability: Int?
    let resetAvailabilityWarMark: String?
}
