import Foundation

/// 活跃订单的**持久化**记录 —— 对照 Android 的 `model/ActiveOrder.kt`。
///
/// ## 字段为什么只有这几个
///
/// 和 Android 一模一样：只有「哪台设备、哪一单、显示成什么、预扣多少」。
/// `protocolType` / `randomNumber` / `consumeDate` 那些**蓝牙会话参数故意不放这里**，
/// 而是另存 `Prefs.bleSessionJson`（Android 也是这么分的）。
/// 两端的数据摆放位置保持一致，排查问题时才不会各说各话。
struct ActiveOrderRecord: Codable, Equatable {
    var snCode: String
    var orderNo: String
    var deviceName: String
    var deviceMac: String
    var deviceEmoji: String
    var preDeduct: Double
    /// 新记录显式保存控制通道；旧记录缺字段时保持未知，由设备台账确认。
    var isBluetooth: Bool? = nil
}

/// 活跃订单仓库 —— 逐条对照 Android 的 `data/ActiveOrderRepository.kt`。
///
/// ## 它解决什么问题
///
/// 「读出整份列表 → 改 → 写回去」这三步不是原子的。界面、结算任务、启动恢复
/// 三条路径并发跑时，后写的会整份覆盖先写的 —— 表现就是**订单凭空消失或复活**。
///
/// 这里用一把锁把整段串行化，并且只暴露语义化操作（`upsert` / `replace` /
/// `remove`），让调用方**没有机会**再写出裸的三步。
///
/// ⚠️ 这份数据是「有没有正在用水」的唯一事实来源：
/// - 首页「使用中的设备」卡片
/// - 启动时的订单恢复
/// - 退出登录的守卫
///
/// 三处都读它，所以只能有一个写入入口。
enum ActiveOrderStore {

    private static let key = "activeOrders"
    private static let finishedKey = "finishedOrderIdentities"
    private struct FinishedOrder: Codable {
        let snCode: String
        let orderNo: String
    }
    /// 递归锁：`record` 之类的方法内部会再调 `all()` / `save()`，普通锁会自锁死
    private static let lock = NSRecursiveLock()

    static func all() -> [ActiveOrderRecord] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    static func find(_ snCode: String) -> ActiveOrderRecord? {
        guard !snCode.isEmpty else { return nil }
        return all().first { $0.snCode == snCode }
    }

    static func isRunning(_ snCode: String) -> Bool {
        guard !snCode.isEmpty else { return false }
        return all().contains { $0.snCode == snCode }
    }

    /// 原子地修改整份列表
    static func update(_ block: (inout [ActiveOrderRecord]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        block(&list)
        save(list)
    }

    /// 加入；已存在同 snCode 的直接替换，不产生重复
    static func upsert(_ order: ActiveOrderRecord) {
        update { list in
            if let i = list.firstIndex(where: { $0.snCode == order.snCode }) {
                list[i] = order
            } else {
                list.append(order)
            }
        }
    }

    /// 就地替换同 snCode 的那条（不存在则忽略 —— 不要凭空创建）
    static func replace(_ order: ActiveOrderRecord) {
        update { list in
            if let i = list.firstIndex(where: { $0.snCode == order.snCode }) {
                list[i] = order
            }
        }
    }

    /// 只补 orderNo。
    ///
    /// ⚠️ 单独一个方法而不是「读出来改再 upsert」：`upsert` 会整条覆盖，
    /// 并发时可能把别的路径刚写进去的字段冲掉。
    static func updateOrderNo(snCode: String, orderNo: String) {
        guard !snCode.isEmpty, !orderNo.isEmpty else { return }
        update { list in
            if let i = list.firstIndex(where: { $0.snCode == snCode }) {
                list[i].orderNo = orderNo
            }
        }
    }

    static func remove(_ snCode: String) {
        guard !snCode.isEmpty else { return }
        update { $0.removeAll { $0.snCode == snCode } }
    }

    /// 已确认关闭与普通删除不同：保留结束身份，拒绝服务端短暂返回的旧订单。
    /// 与活跃记录用同一把锁，避免「刚移除又被查询加回」；退出账号时一起清理。
    static func finish(_ snCode: String) {
        lock.lock(); defer { lock.unlock() }
        if let record = find(snCode) {
            var finished = loadFinished()
            finished.removeAll { $0.snCode == snCode && $0.orderNo == record.orderNo }
            finished.append(FinishedOrder(snCode: snCode, orderNo: record.orderNo))
            if let data = try? JSONEncoder().encode(Array(finished.suffix(128))) {
                UserDefaults.standard.set(data, forKey: finishedKey)
            }
        }
        remove(snCode)
    }

    static func wasFinished(snCode: String, orderNo: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadFinished().contains {
            $0.snCode == snCode && ($0.orderNo == orderNo || $0.orderNo.isEmpty || orderNo.isEmpty)
        }
    }

    /// 确认空闲后，未知订单号的临时拦截可以解除；已知订单号继续去重。
    static func confirmIdle(_ snCode: String) {
        lock.lock(); defer { lock.unlock() }
        let finished = loadFinished().filter { $0.snCode != snCode || !$0.orderNo.isEmpty }
        if let data = try? JSONEncoder().encode(finished) {
            UserDefaults.standard.set(data, forKey: finishedKey)
        }
    }

    private static func loadFinished() -> [FinishedOrder] {
        guard let data = UserDefaults.standard.data(forKey: finishedKey) else { return [] }
        return (try? JSONDecoder().decode([FinishedOrder].self, from: data)) ?? []
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: finishedKey)
    }

    // MARK: - 内部

    private static func load() -> [ActiveOrderRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ActiveOrderRecord].self, from: data)) ?? []
    }

    private static func save(_ list: [ActiveOrderRecord]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
