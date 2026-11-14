import Foundation

/// 从 `0x23` 状态帧里解析出来的字段
struct DeviceState {
    let protocolType: String
    let randomNumber: String
    let state: Int
    let devType: Int
    let a1: Int
    /// 设备自报的 MAC（`p[13..18]`），用于核对是不是目标设备
    let mac: String
    let payloadLength: Int

    var isIdle: Bool { state == 0 }
    /// 已关阀但有遗留未结算记录
    var hasPendingSettle: Bool { state == 3 || state == 6 }

    var describe: String {
        "protocol=\(protocolType.isEmpty ? "-" : protocolType) state=\(state) devType=\(devType) a1=\(a1) random=\(randomNumber.count > 12 ? String(randomNumber.prefix(12)) + "…" : randomNumber)"
    }
}

enum DeviceStateParser {
    /// 解析 `0x23` 载荷。只有 28 字节（短）和 ≥31 字节（长）两种布局。
    static func parse(_ p: [UInt8]) -> DeviceState? {
        guard !p.isEmpty, p[0] == 0x80 else { return nil }

        func hex(_ range: Range<Int>) -> String {
            range.map { String(format: "%02X", p[$0]) }.joined()
        }

        if p.count == 28 {
            return DeviceState(
                protocolType: "",
                randomNumber: hex(21..<23),
                state: Int(p[19]),
                devType: Int(p[23]),
                a1: Int(p[24]),
                mac: p.count >= 19 ? hex(13..<19) : "",
                payloadLength: p.count
            )
        }
        if p.count >= 31 {
            return DeviceState(
                protocolType: String(format: "%02X", p[19]),
                randomNumber: hex(24..<28),
                state: Int(p[28]),
                devType: Int(p[29]),
                a1: Int(p[30]),
                mac: p.count >= 19 ? hex(13..<19) : "",
                payloadLength: p.count
            )
        }
        return nil
    }

}
