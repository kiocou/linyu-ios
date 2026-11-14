import Foundation

enum DeviceAddressRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        check(DeviceAddress.lookupVariants("C0:15:83:04:D3:00") == ["C0:15:83:04:D3:00", "00158304d300"], "台账查询保留原地址优先、公共地址小写兜底")
        check(DeviceAddress.lookupVariants("00158304D300") == ["00158304D300"], "公开地址不重复派生")
        check(DeviceAddress.lookupVariants("bad") == ["bad"], "无效MAC不猜地址")
        let bytes: [UInt8] = [0, 0, 0xC4, 0x7F, 0x0E, 0xDC, 0x7C, 0xFE]
        check(DeviceAddress.advertisedSN(Data(bytes)) == "C47F0EDC7CFE", "严格解析8字节厂商数据")
        check(DeviceAddress.advertisedSN(Data(bytes + [0])) == nil, "拒绝长厂商数据拼凑MAC")
        check(DeviceAddress.advertisedSN(Data([1] + bytes.dropFirst())) == nil, "拒绝其他厂商ID")
        var map = ConfirmedDeviceMap()
        let a = UUID(), b = UUID()
        map.register(["00158304D300", "C0158304D300"], id: a)
        check(map.peripheralID(for: "00:15:83:04:d3:00") == a, "服务端确认的台账与广播别名指向同一对象")
        check(map.peripheralID(for: "00158304D301") == nil, "相邻水表不误匹配")
        map.register(["00158304D300"], id: b)
        check(map.isAmbiguous("00158304D300") && map.peripheralID(for: "00158304D300") == nil, "两台广播争用别名时拒绝连接")
        map.register(["00158304D300"], id: a)
        check(map.peripheralID(for: "00158304D300") == nil, "后续广播不能覆盖身份歧义")

        defer { ApiClient.deviceResponses = [:]; ApiClient.deviceQueries = [] }
        let original = "C0158304D300", derived = "00158304d300"
        let info = #"{"success":true,"data":{"snCode":"00158304D300","deviceName":"测试设备"}}"#
        ApiClient.deviceResponses = [derived: info]
        ApiClient.deviceQueries = []
        let store = AppDataStore()
        await store.deviceInfo(original)
        check(ApiClient.deviceQueries == [original, derived], "只有成功空响应才尝试第二候选")
        check(store.deviceInfos[original]?.snCode == "00158304D300" && store.deviceInfos["00158304D300"] != nil, "台账缓存同时索引广播地址和业务SN")
        ApiClient.deviceResponses = [original: info]
        ApiClient.deviceQueries = []
        _ = try? await DeviceLookup.load(original)
        check(ApiClient.deviceQueries == [original], "原地址命中不增加请求")
        ApiClient.deviceResponses = [original: #"{"success":false,"errorCode":401,"data":null}"#]
        ApiClient.deviceQueries = []
        _ = try? await DeviceLookup.load(original)
        check(ApiClient.deviceQueries == [original], "业务失败不尝试派生地址")
    }
}
