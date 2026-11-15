import Foundation

/// `autoDisConTime` 的取值口径。
///
/// 服务端对**蓝牙表**会回一个很小的值（2026-11-15 真机实测 `autoDisConTime=5`）。
/// 那是设备的**空闲自动断开**参数，已经随 `downData` 下发进设备，
/// 不是「本次用水最多几秒」。
///
/// 3.1.3 把它当会话时长上限，结果开阀 5 秒后 App 自己发 `0x22` 把水关了，
/// 用户看到的就是「刚开就自己关闭」，使用页还从 5 秒开始倒计时。
/// 所以只有明确是分钟级会话上限（≥ 60 秒）的值才进入 App 侧倒计时。
///
/// ⚠️ 这个文件刻意不依赖任何其他类型：CI 用它单独编译倒计时回归。
enum AutoDisconPolicy {
    static let minimumCountdownSeconds = 60

    static func countdownSeconds(from raw: Int?) -> Int {
        guard let raw, raw >= minimumCountdownSeconds else { return 0 }
        return raw
    }
}
