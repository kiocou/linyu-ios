import UIKit

extension UIDevice {

    /// 具体机型标识，如 `iPhone15,2`。
    /// `UIDevice.model` 只会返回 "iPhone"，对排查问题没帮助。
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeMutablePointer(to: &info.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cStr in
                String(cString: cStr)
            }
        }
    }

    /// 注意：不能叫 `systemName` / `systemVersion`——`UIDevice` 本身已有同名的
    /// **实例**属性，再定义一个同名 static 属性会让 Swift 在 static 上下文里
    /// 优先匹配到它自己，报 "static member cannot be used on instance"。
    static var osName: String { UIDevice.current.systemName }
    static var osVersion: String { UIDevice.current.systemVersion }

    /// 把机型标识映射成人能看懂的名字
    static var friendlyModel: String {
        let id = modelIdentifier
        let map: [String: String] = [
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus"
        ]
        return map[id] ?? id
    }
}
