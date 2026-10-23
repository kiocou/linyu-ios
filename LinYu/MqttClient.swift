import Foundation
import Network

/// 极简 MQTT 3.1.1 客户端（QoS 0 / clean session）——
/// 逐条对照 Android 的 `utils/MqttManager.kt`。
///
/// ## 为什么手写而不是引第三方库
///
/// 项目本身零依赖（XcodeGen + 纯 SDK）。而这里要的能力只有四件事：
/// CONNECT → SUBSCRIBE 三个 topic → 收 PUBLISH → 定时 PINGREQ。
/// 用不着 topic 通配、遗嘱、TLS、QoS1/2 那一整套。手写 300 行比引一个
/// 上百万字节的库更容易审，也不会被某个库的最低 iOS 版本卡住。
///
/// ## 它在链路里的位置
///
/// **只是加速器**：实时消费金额靠它推送，但正确性由 HTTP 轮询保证
/// （落账、结算、关阀全走 HTTP）。所以连不上/断线**绝不能**影响开阀流程——
/// 所有失败都降级为「没有实时数字」，不弹错、不阻断。
///
/// ⚠️ 服务端是**明文 TCP**（`tcp://47.107.37.60:1883`），和 Android 一致。
@MainActor
final class MqttClient: ObservableObject {

    /// 服务端地址 —— 与 Android `MqttManager.serverUri` 完全一致
    static let host = "47.107.37.60"
    static let port: UInt16 = 1883
    /// keepAlive 10 秒（Android 也是 10）；发 PINGREQ 的间隔取其一半
    static let keepAliveSeconds: UInt16 = 10
    static let connectTimeout: TimeInterval = 5

    @Published private(set) var connected = false

    private var connection: NWConnection?
    private var rx = Data()
    private var pingTask: Task<Void, Never>?
    private var generation = 0
    private var onMessage: (@MainActor (String) -> Void)?
    private var connectWaiter: CheckedContinuation<Bool, Never>?
    private var connectedPhone = ""

    // MARK: - 对外

    /// 连接并订阅。返回是否成功（失败时调用方继续走 HTTP，不要报错）
    @discardableResult
    func connect(phone: String, onMessage: @escaping @MainActor (String) -> Void) async -> Bool {
        guard !phone.isEmpty else { return false }
        if connected, connectedPhone == phone { return true }

        // 换了手机号（换账号）就先断掉旧会话
        if connectedPhone != phone { disconnect() }

        self.onMessage = onMessage
        connectedPhone = phone
        generation += 1
        let mine = generation

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(
            host: NWEndpoint.Host(Self.host),
            port: NWEndpoint.Port(rawValue: Self.port) ?? 1883,
            using: params
        )
        connection = conn

        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            connectWaiter = cont
            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == mine else { return }
                    switch state {
                    case .ready:
                        // TCP 通了还不算连上：要等 CONNACK
                        self.send(Self.connectPacket(clientId: Self.makeClientId()))
                        self.startReceive()
                    case let .failed(error):
                        self.finishConnect(false, reason: "连接失败：\(error.localizedDescription)")
                    case .cancelled:
                        self.finishConnect(false, reason: "连接被取消")
                    default:
                        break
                    }
                }
            }
            conn.start(queue: .global(qos: .utility))

            // 连接超时（Android 也是 5 秒）
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
                await MainActor.run {
                    guard let self, self.generation == mine, !self.connected else { return }
                    self.finishConnect(false, reason: "连接超时")
                }
            }
        }

        guard ok, generation == mine else {
            // 连不上就彻底收摊：留着半开的连接只会在后台白耗电
            connection?.cancel()
            connection = nil
            return false
        }

        // 订阅三个 topic —— 与 Android 一字不差
        subscribe(["app_downRate_\(phone)", "app_shutdownOrder_\(phone)", "app_uploadData_\(phone)"])
        connected = true
        startPing()
        AppLog.shared.i("MQTT 已连接并订阅（\(Self.host):\(Self.port)）")
        return true
    }

    func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        if let conn = connection, connected {
            send(Self.disconnectPacket())
            conn.cancel()
        } else {
            connection?.cancel()
        }
        connection = nil
        connected = false
        rx.removeAll()
        connectedPhone = ""
        generation += 1
        finishConnect(false, reason: nil)
    }

    // MARK: - 收发

    private func finishConnect(_ ok: Bool, reason: String?) {
        if let reason { AppLog.shared.w("MQTT：\(reason)") }
        connectWaiter?.resume(returning: ok)
        connectWaiter = nil
        if !ok { connected = false }
    }

    private func send(_ data: Data) {
        guard let conn = connection else { return }
        conn.send(content: data, completion: .contentProcessed { error in
            if let error {
                Task { @MainActor in AppLog.shared.w("MQTT 发送失败：\(error.localizedDescription)") }
            }
        })
    }

    private func subscribe(_ topics: [String]) {
        var body = Data()
        body.append(contentsOf: [0x00, 0x01])          // packet id = 1
        for topic in topics {
            body.append(Self.mqttString(topic))
            body.append(0)                              // QoS 0
        }
        var packet = Data([0x82])                       // SUBSCRIBE
        packet.append(Self.remainingLength(body.count))
        packet.append(body)
        send(packet)
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.keepAliveSeconds) * 500_000_000)
                guard !Task.isCancelled, let self, self.connected else { return }
                self.send(Data([0xC0, 0x00]))            // PINGREQ
            }
        }
    }

    private func startReceive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.rx.append(data)
                    self.drain()
                }
                if let error {
                    AppLog.shared.w("MQTT 接收失败：\(error.localizedDescription)")
                    self.dropConnection()
                    return
                }
                if isComplete {
                    AppLog.shared.w("MQTT 连接被对端关闭")
                    self.dropConnection()
                    return
                }
                self.startReceive()
            }
        }
    }

    private func dropConnection() {
        pingTask?.cancel()
        pingTask = nil
        connection?.cancel()
        connection = nil
        connected = false
        rx.removeAll()
    }

    /// 把缓冲区里**完整的**报文逐条处理掉（半包留着等下次）
    private func drain() {
        while true {
            guard rx.count >= 2 else { return }

            // 剩余长度是 1~4 字节变长编码
            var multiplier = 1
            var length = 0
            var index = 1
            var lengthBytes = 0
            while index < rx.count {
                let byte = Int(rx[index])
                length += (byte & 0x7F) * multiplier
                multiplier *= 128
                lengthBytes += 1
                index += 1
                if byte & 0x80 == 0 { break }
                if lengthBytes >= 4 { return }
            }
            guard lengthBytes > 0 else { return }

            let headerLength = 1 + lengthBytes
            guard rx.count >= headerLength + length else { return }   // 半包

            let packet = rx.subdata(in: 0 ..< (headerLength + length))
            rx.removeFirst(headerLength + length)
            handle(packet, headerLength: headerLength)
        }
    }

    private func handle(_ packet: Data, headerLength: Int) {
        guard let first = packet.first else { return }
        let type = first >> 4
        let payload = packet.subdata(in: headerLength ..< packet.count)

        switch type {
        case 2:
            // CONNACK：payload = [sessionPresent, returnCode]
            let code = payload.count >= 2 ? payload[1] : 0xFF
            if code == 0 {
                finishConnect(true, reason: nil)
            } else {
                finishConnect(false, reason: "CONNACK 拒绝（code=\(code)）")
            }

        case 9:
            AppLog.shared.i("MQTT 订阅成功")

        case 3:
            // PUBLISH（QoS 0，没有 packet id）
            guard payload.count >= 2 else { return }
            let topicLength = Int(payload[0]) << 8 | Int(payload[1])
            guard payload.count >= 2 + topicLength else { return }
            let body = payload.subdata(in: (2 + topicLength) ..< payload.count)
            let text = String(data: body, encoding: .utf8) ?? ""
            if !text.isEmpty { onMessage?(text) }

        case 13:
            break   // PINGRESP

        default:
            break
        }
    }

    // MARK: - 报文编码

    private static func makeClientId() -> String {
        // Android 用 MqttClient.generateClientId()，这里等价地生成一个随机 id
        "linyu-ios-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
    }

    private static func mqttString(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        var out = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        out.append(bytes)
        return out
    }

    /// MQTT 变长整数（剩余长度）
    private static func remainingLength(_ length: Int) -> Data {
        var value = length
        var out = Data()
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }

    private static func connectPacket(clientId: String) -> Data {
        var body = Data()
        body.append(mqttString("MQTT"))         // 协议名
        body.append(4)                          // 协议级别 3.1.1
        body.append(0x02)                       // flags：clean session
        body.append(UInt8(keepAliveSeconds >> 8))
        body.append(UInt8(keepAliveSeconds & 0xFF))
        body.append(mqttString(clientId))

        var packet = Data([0x10])               // CONNECT
        packet.append(remainingLength(body.count))
        packet.append(body)
        return packet
    }

    private static func disconnectPacket() -> Data {
        Data([0xE0, 0x00])
    }
}
