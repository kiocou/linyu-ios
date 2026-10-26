import Foundation

enum BleCallbackRegression {
    static func run(check: (Bool, String) -> Void) {
        var guardState = BleCallbackGuard()
        let a = UUID(), b = UUID()
        let first = guardState.begin(a)!
        check(guardState.accepts(a, generation: first), "蓝牙当前设备与连接代次匹配")
        check(!guardState.accepts(b, generation: first), "其他设备回调不属于当前连接")
        guardState.retire(a, waitForTerminal: true)
        check(!guardState.accepts(a, generation: first), "断开请求后旧回调失效")
        check(guardState.begin(a) == nil, "同设备收到终止回调前不能重连")
        let second = guardState.begin(b)!
        check(guardState.finishRetiring(a), "旧设备终止只解除旧连接屏障")
        check(guardState.accepts(b, generation: second), "旧设备断开不结束另一设备新连接")
        guardState.retire(b, waitForTerminal: false)
        let third = guardState.begin(a)!
        check(!guardState.accepts(a, generation: first) && guardState.accepts(a, generation: third),
              "同设备重连后旧超时不匹配新代次")
        check(!guardState.finishRetiring(a), "当前设备意外断开不会被当成已退休连接")
        guardState.retire(a, waitForTerminal: true)
        check(!guardState.finishRetiring(b) && guardState.isRetiring(a), "其他设备终止不能解除目标屏障")
        check(guardState.finishRetiring(a) && guardState.begin(a) != nil, "收到目标终止事件后允许重连")
    }
}
