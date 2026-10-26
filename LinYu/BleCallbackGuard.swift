import Foundation

/// CoreBluetooth 不提供连接请求编号：同设备必须等旧连接终止后才可复用。
struct BleCallbackGuard {
    private(set) var generation = UUID()
    private(set) var device: UUID?
    private var retiring: Set<UUID> = []

    func isRetiring(_ id: UUID) -> Bool { retiring.contains(id) }
    mutating func begin(_ id: UUID) -> UUID? {
        guard !isRetiring(id) else { return nil }
        generation = UUID()
        device = id
        return generation
    }
    func accepts(_ id: UUID, generation token: UUID) -> Bool {
        device == id && generation == token && !isRetiring(id)
    }
    mutating func retire(_ id: UUID, waitForTerminal: Bool) {
        if waitForTerminal { retiring.insert(id) }
        if device == id { device = nil; generation = UUID() }
    }
    /// true 表示旧连接终止，不能再当作当前连接的故障。
    mutating func finishRetiring(_ id: UUID) -> Bool {
        retiring.remove(id) != nil
    }
}
