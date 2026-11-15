import Foundation

/// `autoDisConTime` 口径回归。
///
/// 2026-11-15 真机 `/order/downRate/bluetooth/rateOrder` 回的是 `autoDisConTime=5`：
/// 那是设备的**空闲自动断开**参数（已随 downData 下发进设备），
/// 不是「本次用水最多几秒」。3.1.3 拿它当会话时长上限，
/// 结果开阀 5 秒后 App 自己发 0x22 把水关了 —— 用户看到「刚开就自己关闭」。
@main struct AutoDisconRegression {
    static func main() {
        var failures = 0
        func check(_ result: Bool, _ message: String) {
            print("\(result ? "PASS" : "FAIL"): \(message)")
            if !result { failures += 1 }
        }

        check(AutoDisconPolicy.countdownSeconds(from: 5) == 0, "蓝牙表 5 秒的值不进入 App 倒计时")
        check(AutoDisconPolicy.countdownSeconds(from: 1) == 0, "1 秒同样不当作会话时长")
        check(AutoDisconPolicy.countdownSeconds(from: 59) == 0, "低于一分钟一律不倒计时")
        check(AutoDisconPolicy.countdownSeconds(from: 60) == 60, "分钟级会话上限保留")
        check(AutoDisconPolicy.countdownSeconds(from: 300) == 300, "云端常用 5 分钟保留")
        check(AutoDisconPolicy.countdownSeconds(from: 0) == 0, "0 表示没有倒计时")
        check(AutoDisconPolicy.countdownSeconds(from: nil) == 0, "字段缺失不倒计时")

        if failures > 0 {
            print("FAILURES: \(failures)")
            exit(1)
        }
        print("AutoDisconRegression: all checks passed")
    }
}
