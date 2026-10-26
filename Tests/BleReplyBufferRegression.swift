import Foundation

enum BleReplyBufferRegression {
    static func run(check: (Bool, String) -> Void) {
        var buffer = BleReplyBuffer()
        buffer.offer(command: 0x23, payload: [9])
        let first = buffer.begin(command: 0x23)!
        check(buffer.take(first) == nil, "发送前的主动推帧不成为本次应答")
        check(buffer.begin(command: 0x22) == nil, "不能同时发送两条蓝牙命令")
        buffer.offer(command: 0x85, payload: [8])
        check(buffer.take(first) == nil, "丢弃非期望命令的主动帧")
        buffer.offer(command: 0x23, payload: [0x80, 1])
        buffer.offer(command: 0x23, payload: [0x80, 2])
        check(buffer.take(first) == [0x80, 1], "写入期间先到的应答保留首帧")
        check(buffer.take(first) == nil, "提前应答只消费一次")
        buffer.finish(first)
        let second = buffer.begin(command: 0x23)!
        buffer.finish(first)
        buffer.offer(command: 0x23, payload: [3])
        check(buffer.take(second) == [3], "旧命令收尾不清理新命令的应答")
        buffer.reset()
        buffer.offer(command: 0x23, payload: [4])
        let third = buffer.begin(command: 0x23)!
        check(buffer.take(third) == nil, "断开重连不带入上次缓存应答")
    }
}
