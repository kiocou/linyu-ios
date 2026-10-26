import Foundation
import Combine
import UIKit

/// 一条日志
struct LogLine: Identifiable, Hashable {
    enum Level: String {
        case info = "I"
        case warn = "W"
        case error = "E"
    }

    let id = UUID()
    let time: Date
    let level: Level
    let message: String
    /// 附加内容（如请求体/响应体、帧 hex）。单独一栏，方便折叠
    let detail: String?

    var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: time)
    }
}

/// 应用内日志。
///
/// ## 为什么要内置日志
///
/// 这个 App 的核心链路是「云端下费率 → 蓝牙写设备 → 采集 → 上传结算」，
/// 任何一环出错都只在现场发生，用户描述「开不了阀」和「扣错钱」看起来一样。
/// 所以每次操作的关键数据都必须落到本地文件，用户能一键导出给我看。
///
/// ## 脱敏
///
/// 手机号、loginCode、签名、明文密码一律打码。这类日志用户要发给别人，
/// 不能带凭证。
final class AppLog: ObservableObject {

    static let shared = AppLog()

    /// 内存里保留的条数上限（界面只看最近这些）
    private let maxMemoryLines = 800
    private let maxFileSize = 2 * 1024 * 1024   // 2MB

    @Published private(set) var lines: [LogLine] = []

    private let fileURL: URL
    private let queue = DispatchQueue(label: "linyu.applog", qos: .utility)
    private let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("linyu-runtime.log")
    }

    // MARK: - 写入

    func i(_ message: String, _ detail: String? = nil) { append(.info, message, detail) }
    func w(_ message: String, _ detail: String? = nil) { append(.warn, message, detail) }
    func e(_ message: String, _ detail: String? = nil) { append(.error, message, detail) }

    private func append(_ level: LogLine.Level, _ message: String, _ detail: String?) {
        let line = LogLine(
            time: Date(),
            level: level,
            message: Self.mask(message),
            detail: detail.map(Self.mask)
        )

        // 界面更新必须在主线程
        if Thread.isMainThread {
            push(line)
        } else {
            DispatchQueue.main.async { [weak self] in self?.push(line) }
        }

        // 文件写入放后台，避免阻塞蓝牙回调
        queue.async { [weak self] in
            guard let self else { return }
            var text = "[\(self.df.string(from: line.time))] [\(line.level.rawValue)] \(line.message)\n"
            if let d = line.detail, !d.isEmpty {
                text += "  \(d.replacingOccurrences(of: "\n", with: "\n  "))\n"
            }
            self.appendFile(text)
        }
    }

    private func push(_ line: LogLine) {
        lines.append(line)
        if lines.count > maxMemoryLines {
            lines.removeFirst(lines.count - maxMemoryLines)
        }
    }

    private func appendFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        // 超过上限时截断前一半，保留最近的
        if let size = try? handle.seekToEnd(), size > UInt64(maxFileSize) {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    // MARK: - 导出

    /// 对照 Android exportLogs：优先导出文件末尾 500 行，取不到再用内存。
    func exportFile(note: String? = nil) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "linyu-log-\(f.string(from: Date())).txt"

        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(name)

        // 等待已排队的文件写入完成，确保刚发生的错误也包含在导出里。
        let history = queue.sync {
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
        var recent = history.split(separator: "\n", omittingEmptySubsequences: false)
        if recent.last == "" { recent.removeLast() }
        if recent.isEmpty {
            let memory = lines.map { line in
                var text = "[\(line.timeText)] [\(line.level.rawValue)] \(line.message)"
                if let detail = line.detail, !detail.isEmpty {
                    text += "\n  " + detail.replacingOccurrences(of: "\n", with: "\n  ")
                }
                return text
            }.joined(separator: "\n")
            recent = memory.split(separator: "\n", omittingEmptySubsequences: false)
            if recent.last == "" { recent.removeLast() }
        }
        guard !recent.isEmpty else { w("没有可导出的日志"); return nil }
        let text = header(note: note) + "\n" + recent.suffix(500).joined(separator: "\n") + "\n"

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func header(note: String?) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let dfFull = DateFormatter()
        dfFull.locale = Locale(identifier: "en_US_POSIX")
        dfFull.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var s = """
        # LinYu iOS 运行日志
        导出时间: \(dfFull.string(from: Date()))
        App 版本: \(version) (\(build))
        设备: \(UIDevice.modelIdentifier) / \(UIDevice.osName) \(UIDevice.osVersion)
        登录: \(Session.shared.isLoggedIn ? "是（projectId=\(Session.shared.projectId)）" : "否")

        """
        if let note, !note.isEmpty { s += "备注: \(note)\n\n" }
        return s
    }

    func clear() {
        lines.removeAll()
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    // MARK: - 脱敏

    /// 手机号、loginCode、签名、密码一律打码
    static func mask(_ s: String) -> String {
        LogRedactor.mask(s)
    }
}
