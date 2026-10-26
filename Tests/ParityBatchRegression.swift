import Foundation

enum ParityBatchRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        defer { ApiClient.getResponses = [:]; ProfileCache.clear() }
        for raw in ["55460", "0", "null"] {
            ApiClient.getResponses["/account/wallet"] = "{\"success\":true,\"data\":{\"accountRealMoney\":\(raw),\"money\":\"55.460\"}}"
            await BillService.refreshBalances()
            check(Double(Prefs.walletBalance) == 55.46, "钱包使用元字段，忽略厘字段 \(raw)")
        }
        ApiClient.getResponses["/account/wallet"] = #"{"success":true,"data":{"accountRealMoney":55460}}"#
        await BillService.refreshBalances()
        check(Prefs.walletBalance.isEmpty, "缺少元字段不把厘误当元")

        var short = [UInt8](repeating: 0, count: 28)
        short[0] = 0x80; short[19] = 6; short[21] = 0xAB; short[22] = 0xCD
        short[23] = 4; short[24] = 1
        let s = DeviceStateParser.parse(short)
        check(s?.protocolType == "" && s?.randomNumber == "ABCD", "短帧保留两字节挑战值、不猜协议版本")
        check(s?.hasPendingSettle == true && s?.devType == 4 && s?.a1 == 1, "短帧状态与设备类型偏移正确")
        let device = try! JSONDecoder().decode(DeviceInfo.self, from: Data("{}".utf8))
        let rate = BleRequestFields.rate(device: device, deviceId: "1", mac: "A", macType: "0401", state: s!, xfModel: "0", signature: "sig")
        check(rate["randomNumber"] == "abcd" && rate["protocolType"] == "", "费率请求挑战值小写且短帧协议不伪造")
        check(rate["bigTypeId"] == "0" && rate["smallTypeId"] == "0", "缺失类型按安卓默认0发送")
        let upload = BleRequestFields.upload(protocolType: "20", randomNumber: "ABCDEF01", xfData: "80AB", signature: "sig")
        check(upload["randomNumber"] == "abcdef01" && upload["xfData"] == "80ab", "结算上传挑战值和消费体均为小写")
        var long = [UInt8](repeating: 0, count: 49)
        long[0] = 0x80; long[19] = 0x20; long[24] = 0xAB; long[25] = 0xCD; long[26] = 0xEF; long[27] = 1
        long[28] = 1; long[29] = 4; long[30] = 2
        long.replaceSubrange(13..<19, with: [0xC4, 0x7F, 0x0E, 0xDC, 0x7C, 0xFE])
        let l = DeviceStateParser.parse(long)
        check(l?.randomNumber == "ABCDEF01" && l?.protocolType == "20", "长帧保留四字节挑战值和协议")
        check(l?.mac == "C47F0EDC7CFE" && l?.state == 1 && l?.devType == 4 && l?.a1 == 2, "长帧设备身份与状态正确")
        check(DeviceStateParser.parse(Array(long.prefix(31)))?.state == 1, "31字节边界可解析")
        for count in [0, 1, 19, 27, 29, 30] {
            check(DeviceStateParser.parse(Array(long.prefix(count))) == nil, "拒绝未知长度 \(count)")
        }
        long[0] = 0x81
        check(DeviceStateParser.parse(long) == nil, "拒绝非成功状态帧")

        check(LoginFeedback.message(URLError(.notConnectedToInternet)) == "网络异常，请重试", "断网提示中文")
        check(LoginFeedback.message(URLError(.timedOut)) == "连接超时，请重试", "超时提示中文")
        check(LoginFeedback.message(URLError(.secureConnectionFailed)) == "安全连接失败，请重试", "安全连接错误使用简短中文")
        check(LoginFeedback.message(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed."])) == "网络异常，请重试", "未知英文错误不透出界面")
        check(LoginFeedback.chineseMessage("设备不在线") == "设备不在线", "中文业务原因保留")
        check(LoginFeedback.chineseMessage("Internal Server Error") == "请求失败，请稍后重试", "服务端英文错误使用中文兜底")

        ProfileCache.clear()
        ApiClient.getResponses = [
            "/account/info": #"{"success":true,"data":{"name":"","telephone":"123"}}"#,
            "/account/card/getBindCardInfo": #"{"success":true,"data":{"name":"测试姓名"}}"#,
            "/settlement/campus/userInfo": #"{"success":true,"data":{"studentName":"另一来源","studentNumber":"S123"}}"#,
            "/project/info/triple": #"{"success":true,"data":{"projectName":"测试学校"}}"#
        ]
        let profile = AppDataStore(profileOwnerProvider: { "school:A" })
        await profile.loadProfileIfNeeded()
        check(profile.accountInfo?.name == "测试姓名" && profile.accountInfo?.idCardNumber == "S123", "账号空字段由绑定卡和一卡通补齐，不覆盖已有姓名")
        check(profile.projectName == "测试学校" && profile.profileLoaded, "学校与身份均可展示")
        let restored = AppDataStore(profileOwnerProvider: { "school:A" })
        check(restored.profileLoaded && restored.accountInfo?.idCardNumber == "S123", "冷启动立即读取同账号缓存")
        check(!AppDataStore(profileOwnerProvider: { "school:B" }).profileLoaded, "另一账号不能读取缓存")
        ApiClient.getResponses["/account/info"] = #"{"success":true,"data":{"name":"新姓名","idCardNumber":"S456"}}"#
        ApiClient.getPaths = []
        await restored.loadProfileIfNeeded()
        check(restored.accountInfo?.name == "新姓名", "有缓存仍向服务端刷新")
        check(!ApiClient.getPaths.contains("/account/card/getBindCardInfo"), "资料完整不额外请求绑定卡")
        ApiClient.getResponses["/account/info"] = #"{"success":true,"data":null}"#
        ApiClient.getResponses["/project/info/triple"] = #"{"success":true,"data":null}"#
        let failed = AppDataStore(profileOwnerProvider: { "school:A" })
        await failed.loadProfileIfNeeded()
        check(failed.accountInfo?.name == "新姓名" && failed.profileError != nil, "刷新失败保留缓存并提供重试")
        var owner = "school:A"
        let stale = AppDataStore(profileOwnerProvider: { owner })
        ApiClient.getResponses["/account/info"] = #"{"success":true,"data":{"name":"过期响应","idCardNumber":"OLD"}}"#
        ApiClient.getPaths = []
        ApiClient.delay = 20_000_000
        let request = Task { await stale.loadProfileIfNeeded() }
        while ApiClient.activeRequests == 0 { await Task.yield() }
        owner = "school:B"
        await request.value
        ApiClient.delay = 0
        check(ProfileCache.read(owner: "school:B") == nil, "切换账号后旧请求不写入新账号缓存")
        check(ProfileCache.read(owner: "school:A")?.info.name == "新姓名" && stale.accountInfo?.name == "新姓名", "过期响应不更新原账号缓存和页面")
        check(!ApiClient.getPaths.contains("/account/card/getBindCardInfo"), "切换账号后不再发起资料补全请求")
        ProfileCache.clear()
        check(ProfileCache.read(owner: "school:A") == nil, "退出清除资料缓存")
    }
}
