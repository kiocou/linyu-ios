import Foundation

/// 对齐 Android incoming Channel：保留写入期间先到达的本次应答。
/// 只容纳一条串行命令的首帧，不积累无关广播或上一条命令的帧。
struct BleReplyBuffer {
    private var token: UUID?
    private var command: UInt8?
    private var payload: [UInt8]?

    mutating func begin(command: UInt8) -> UUID? {
        guard token == nil else { return nil }
        let id = UUID()
        token = id
        self.command = command
        payload = nil
        return id
    }
    mutating func offer(command: UInt8, payload: [UInt8]) {
        guard token != nil, self.command == command, self.payload == nil else { return }
        self.payload = payload
    }
    mutating func take(_ id: UUID) -> [UInt8]? {
        guard token == id else { return nil }
        let result = payload
        payload = nil
        return result
    }
    mutating func finish(_ id: UUID) {
        guard token == id else { return }
        reset()
    }
    mutating func reset() { token = nil; command = nil; payload = nil }
}
