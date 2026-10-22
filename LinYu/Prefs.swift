import Foundation

/// 本地偏好 —— 对照 Android 的 `PrefsHelper`（只放**非敏感**数据）。
///
/// ⚠️ 凭证（loginCode / 手机号）一律走 `Session` 的 Keychain，不进这里。
/// Android 那边用 EncryptedSharedPreferences；iOS 的等价物是 Keychain，
/// 而 UserDefaults 是**明文**的，混用等于把钥匙挂在门上。
enum Prefs {
    private static var d: UserDefaults { .standard }

    // MARK: - 上次使用的设备

    static var lastDeviceName: String {
        get { d.string(forKey: "lastDeviceName") ?? "" }
        set { d.set(newValue, forKey: "lastDeviceName") }
    }
    static var lastDeviceMac: String {
        get { d.string(forKey: "lastDeviceMac") ?? "" }
        set { d.set(newValue, forKey: "lastDeviceMac") }
    }
    static var lastDeviceSnCode: String {
        get { d.string(forKey: "lastDeviceSnCode") ?? "" }
        set { d.set(newValue, forKey: "lastDeviceSnCode") }
    }
    static var lastDeviceEmoji: String {
        get { d.string(forKey: "lastDeviceEmoji") ?? "🚿" }
        set { d.set(newValue, forKey: "lastDeviceEmoji") }
    }

    // MARK: - 寝室筛选

    static var boundRoom: String {
        get { d.string(forKey: "boundRoom") ?? "" }
        set { d.set(newValue, forKey: "boundRoom") }
    }

    // MARK: - 余额

    /// 一卡通余额（`/settlement/campus/userInfo` 的 `amount`，字符串原样存）
    static var campusBalance: String {
        get { d.string(forKey: "campusBalance") ?? "" }
        set { d.set(newValue, forKey: "campusBalance") }
    }
    /// 趣智校园钱包余额（`/account/wallet` 的 `accountRealMoney`）
    static var walletBalance: String {
        get { d.string(forKey: "walletBalance") ?? "" }
        set { d.set(newValue, forKey: "walletBalance") }
    }
    /// 手填的初始余额（拿不到任何真实余额时才用）
    static var manualBalance: String {
        get { d.string(forKey: "manualBalance") ?? "" }
        set { d.set(newValue, forKey: "manualBalance") }
    }
    static var manualBalanceTime: Double {
        get { d.double(forKey: "manualBalanceTime") }
        set { d.set(newValue, forKey: "manualBalanceTime") }
    }

    // MARK: - 用户确认过「需要蓝牙」的设备

    /// 306 之后用户选了「用蓝牙开启」的设备。
    ///
    /// 下次再开这台就**直接走蓝牙**，不再白试一次云端、再吃一句 306。
    /// 存的是 snCode。
    static var bleDevices: Set<String> {
        get { Set(d.stringArray(forKey: "bleDevices") ?? []) }
        set { d.set(Array(newValue), forKey: "bleDevices") }
    }

    static func isBleDevice(_ sn: String) -> Bool {
        guard !sn.isEmpty else { return false }
        return bleDevices.contains(sn)
    }

    static func markBleDevice(_ sn: String) {
        guard !sn.isEmpty else { return }
        var s = bleDevices
        s.insert(sn)
        bleDevices = s
    }

    static func unmarkBleDevice(_ sn: String) {
        var s = bleDevices
        s.remove(sn)
        bleDevices = s
    }

    // MARK: - 设置项

    static var notifyEnabled: Bool {
        get { d.object(forKey: "notifyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyEnabled") }
    }
    static var notifyInUse: Bool {
        get { d.object(forKey: "notifyInUse") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyInUse") }
    }
    static var notifyFinished: Bool {
        get { d.object(forKey: "notifyFinished") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyFinished") }
    }
    static var notifyAutoClose: Bool {
        get { d.object(forKey: "notifyAutoClose") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyAutoClose") }
    }
    static var notifyAlert: Bool {
        get { d.object(forKey: "notifyAlert") as? Bool ?? false }
        set { d.set(newValue, forKey: "notifyAlert") }
    }

    static var trendEnabled: Bool {
        get { d.object(forKey: "trendEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "trendEnabled") }
    }
    /// `LAST_7_DAYS` / `THIS_MONTH`
    static var trendRange: String {
        get { d.string(forKey: "trendRange") ?? "LAST_7_DAYS" }
        set { d.set(newValue, forKey: "trendRange") }
    }
    /// `BAR` / `LINE`
    static var trendChartType: String {
        get { d.string(forKey: "trendChartType") ?? "LINE" }
        set { d.set(newValue, forKey: "trendChartType") }
    }
    static var trendCollapsed: Bool {
        get { d.object(forKey: "trendCollapsed") as? Bool ?? false }
        set { d.set(newValue, forKey: "trendCollapsed") }
    }

    // MARK: - 上次消费

    static var lastConsumeYuan: Double {
        get { d.double(forKey: "lastConsumeYuan") }
        set { d.set(newValue, forKey: "lastConsumeYuan") }
    }
}

/// 账户余额 —— 逐条对照 Android 的 `data/BalanceEstimator.kt`。
///
/// **三个来源，按优先级取第一个拿得到的：**
///
/// | 优先级 | 来源 | 接口 | 什么学校有 |
/// |---|---|---|---|
/// | 1 | 一卡通 | `GET /settlement/campus/userInfo` | 接了校园卡免密支付 |
/// | 2 | 趣智校园钱包 | `GET /account/wallet` | 几乎所有学校都有 |
/// | 3 | 本地估算 | — | 前两者都拿不到时的兜底 |
///
/// ⚠️ 一卡通**优先**是为了不动已有学校的行为；钱包只在一卡通拿不到时补位。
/// 界面上的标题也要跟着来源变（「一卡通余额」/「趣智校园余额」/「余额」），
/// 全写成「余额」的话，显示钱包余额的学校会以为在说一卡通，对不上账。
enum BalanceEstimator {

    static var campusYuan: Double? {
        let s = Prefs.campusBalance
        return s.isEmpty ? nil : Double(s)
    }

    static var walletYuan: Double? {
        let s = Prefs.walletBalance
        return s.isEmpty ? nil : Double(s)
    }

    static var realBalance: Double? { campusYuan ?? walletYuan }

    static var hasRealBalance: Bool { realBalance != nil }
    static var hasCampusBalance: Bool { campusYuan != nil }
    static var hasWalletBalance: Bool { walletYuan != nil }

    /// 余额标题 —— 按**钱在哪**写
    static var title: String {
        if hasCampusBalance { return "一卡通余额" }
        if hasWalletBalance { return "趣智校园余额" }
        return "余额"
    }

    /// 余额来源说明（卡片底部那行小字）
    static var sourceText: String {
        if hasCampusBalance { return "来自校园卡账户的实时余额" }
        if hasWalletBalance { return "来自趣智校园账户的实时余额" }
        return "仅通过初始金额和账单进行估算，并非真实余额"
    }

    /// 账单里的日期 → 毫秒时间戳；解析不了返回 0（会被当成「早于填余额的时刻」）
    static func billTimeMs(_ consumeDate: String) -> Double {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = f.date(from: consumeDate) { return d.timeIntervalSince1970 * 1000 }
        // 有的账单只到分钟
        f.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = f.date(from: consumeDate) { return d.timeIntervalSince1970 * 1000 }
        return 0
    }

    /// 有真实余额就直接用它；否则 = 手填初始余额 − 填完之后产生的消费
    static func estimate(_ bills: [BillDTO]) -> Double {
        if let real = realBalance { return real }
        let initial = Prefs.manualBalance
        guard !initial.isEmpty, let base = Double(initial) else { return 0 }
        let since = Prefs.manualBalanceTime
        let spent = bills
            .filter { billTimeMs($0.consumeDate ?? "") > since }
            .reduce(0.0) { $0 + ($1.yuan ?? 0) }
        return base - spent
    }

    /// 没填过初始余额、也拿不到真实余额时显示「—」，免得被当成余额为 0
    static func format(_ balance: Double) -> String {
        if !hasRealBalance && Prefs.manualBalance.isEmpty { return "¥ —" }
        return "¥ \(MoneyFormat.format(balance))"
    }
}
