import Foundation

/// 水控设备的**帧协议**（纯函数，无状态，可单测）。
///
/// 移植自 Android 的 `ble/BleFrame.kt`，字节级完全一致。
///
/// ## 二进制帧
///
/// ```
/// 下标:  0     1     2        3     4     5      6 … 6+n-1   6+n    7+n
/// 含义: 0x60  0x00  len+3   0x80  cmd   0x00   data[…]     crc   0x16
/// ```
///
/// - `len` = `data.count + 3`（下标 3、4、5 三个字节算进长度）
/// - **crc** = `(sum(data) + 0x80 + cmd) % 256`
/// - 总长 = `data.count + 8`
///
/// ## 线上帧（真正写入 BLE 特征的字节）
///
/// ```
/// 0x23('#') + 二进制帧的大写 HEX 文本(ASCII) + 0x0A('\n')
/// ```
///
/// ⚠️ 发的是 **HEX 文本**而不是原始二进制——直接写二进制，设备不会报错，
/// 只会静默不理你。这个坑 Android 端踩过，注释里专门写了。
enum BleFrame {

    static let head: UInt8 = 0x60
    static let tail: UInt8 = 0x16
    static let wireStart: UInt8 = 0x23   // '#'
    static let wireEnd: UInt8 = 0x0A     // '\n'
    private static let flag: UInt8 = 0x80

    // MARK: - 组帧

    /// 组二进制帧
    static func build(cmd: UInt8, data: [UInt8] = []) -> [UInt8] {
        let len = data.count + 3
        var frame = [UInt8](repeating: 0, count: data.count + 8)
        frame[0] = head
        frame[1] = 0
        frame[2] = UInt8(truncatingIfNeeded: len)
        frame[3] = flag
        frame[4] = cmd
        frame[5] = 0
        for (i, b) in data.enumerated() { frame[6 + i] = b }

        let sum = data.reduce(0) { $0 + Int($1) }
        frame[6 + data.count] = UInt8(truncatingIfNeeded: (sum + Int(flag) + Int(cmd)) % 256)
        frame[7 + data.count] = tail
        return frame
    }

    /// 二进制帧 → 线上帧（`#` + 大写 HEX + `\n`）
    static func toWire(_ frame: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [wireStart]
        out.append(contentsOf: Array(toHex(frame).utf8))
        out.append(wireEnd)
        return out
    }

    /// 组帧并转线上格式，一步到位
    static func cmdToWire(cmd: UInt8, data: [UInt8] = []) -> [UInt8] {
        toWire(build(cmd: cmd, data: data))
    }

    // MARK: - 解帧

    /// 解析一条完整的线上帧（必须以 `0x0A` 结尾）。格式或 CRC 不合法返回 nil。
    static func parseWire(_ wire: [UInt8]) -> [UInt8]? {
        guard let last = wire.last, last == wireEnd else { return nil }
        let start = (wire.first == wireStart) ? 1 : 0
        let hexLen = wire.count - start - 1
        guard hexLen > 0, hexLen % 2 == 0 else { return nil }

        let hexBytes = Array(wire[start..<(start + hexLen)])
        guard let hexStr = String(bytes: hexBytes, encoding: .ascii),
              let frame = fromHex(hexStr)
        else { return nil }

        return verify(frame) ? frame : nil
    }

    /// 校验魔数、长度、结尾与 CRC
    static func verify(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 8 else { return false }
        guard frame[0] == head else { return false }

        let len = Int(frame[2])
        guard frame.count == len + 5 else { return false }   // 总长 = (len-3)+8
        guard frame[frame.count - 1] == tail else { return false }

        let dataLen = len - 3
        guard dataLen >= 0 else { return false }

        var sum = 0
        for i in 0..<dataLen { sum += Int(frame[6 + i]) }
        let expected = (sum + Int(frame[3]) + Int(frame[4])) % 256
        return Int(frame[frame.count - 2]) == expected
    }

    /// 取载荷（下标 6 起的 data 区）
    static func payloadOf(_ frame: [UInt8]) -> [UInt8]? {
        guard verify(frame) else { return nil }
        let dataLen = Int(frame[2]) - 3
        guard dataLen >= 0 else { return nil }
        return Array(frame[6..<(6 + dataLen)])
    }

    /// 帧里的命令字
    static func cmdOf(_ frame: [UInt8]) -> UInt8 { frame[4] }

    // MARK: - hex 工具

    private static let hexChars = Array("0123456789ABCDEF")

    /// 字节数组 → **大写** HEX
    static func toHex(_ bytes: [UInt8]) -> String {
        var s = ""
        s.reserveCapacity(bytes.count * 2)
        for b in bytes {
            s.append(hexChars[Int(b >> 4)])
            s.append(hexChars[Int(b & 0x0F)])
        }
        return s
    }

    /// 带空格的大写 HEX，便于和日志对照
    static func toHexSpaced(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// HEX → 字节数组（大小写都认），非法输入返回 nil
    static func fromHex(_ hex: String) -> [UInt8]? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexVal(chars[i]), let lo = hexVal(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func hexVal(_ c: Character) -> UInt8? {
        guard let a = c.asciiValue else { return nil }
        switch a {
        case 0x30...0x39: return a - 0x30                    // 0-9
        case 0x61...0x66: return a - 0x61 + 10               // a-f
        case 0x41...0x46: return a - 0x41 + 10               // A-F
        default: return nil
        }
    }

    /// 取 4 字节大端整数（协议里金额、accountId 都是这个字节序）
    static func intAt(_ data: [UInt8], _ offset: Int) -> Int {
        var v = 0
        for i in 0..<4 { v = (v << 8) | Int(data[offset + i]) }
        return v
    }
}
