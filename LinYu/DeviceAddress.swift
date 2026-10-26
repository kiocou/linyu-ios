import Foundation

/// 对照 Android data/MacFormat：派生地址仅是查询候选，不代表已确认同一台表。
enum DeviceAddress {
    static func normalize(_ value: String) -> String? {
        let hex = value.filter { $0.isLetter || $0.isNumber }.uppercased()
        guard hex.count == 12, hex.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        return hex
    }
    static func lookupVariants(_ value: String) -> [String] {
        guard let hex = normalize(value), let first = UInt8(hex.prefix(2), radix: 16), first & 0xC0 != 0 else { return [value] }
        let derived = String(format: "%02x", first & 0x3F) + hex.dropFirst(2).lowercased()
        return derived == value ? [value] : [value, derived]
    }
    static func advertisedSN(_ data: Data?) -> String? {
        guard let data, data.count == 8 else { return nil }
        let bytes = Array(data)
        guard bytes[0] == 0, bytes[1] == 0 else { return nil }
        return bytes.dropFirst(2).map { String(format: "%02X", $0) }.joined()
    }
}

enum DeviceLookup {
    static func load(_ address: String) async throws -> DeviceInfo? {
        guard !address.isEmpty else { return nil }
        for candidate in DeviceAddress.lookupVariants(address) {
            try Task.checkCancellation()
            let raw = try await ApiClient.get("/device/info/mac", query: ["macAddress": candidate], tag: "deviceInfo")
            let response = try ApiClient.decode(DeviceInfo.self, from: raw, path: "deviceInfo")
            guard response.success else { return nil }
            if let info = response.data { return info }
        }
        return nil
    }
}

struct ConfirmedDeviceMap {
    private var devices: [String: UUID] = [:]
    private var ambiguous: Set<String> = []
    private func key(_ value: String) -> String { DeviceAddress.normalize(value) ?? value }
    func isAmbiguous(_ value: String) -> Bool { ambiguous.contains(key(value)) }
    func peripheralID(for value: String) -> UUID? { devices[key(value)] }
    mutating func register(_ values: [String], id: UUID) {
        for value in values where !value.isEmpty {
            let k = key(value)
            if let previous = devices[k], previous != id {
                ambiguous.insert(k)
                devices.removeValue(forKey: k)
            } else if !ambiguous.contains(k) { devices[k] = id }
        }
    }
}
