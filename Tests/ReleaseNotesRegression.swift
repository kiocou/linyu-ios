import Foundation

@main struct ReleaseNotesRegression {
    static func main() async throws {
        var failures = 0
        func check(_ result: Bool, _ message: String) {
            print("\(result ? "PASS" : "FAIL"): \(message)")
            if !result { failures += 1 }
        }
        let doc = try String(contentsOfFile: "docs/APP_CHANGELOG.md", encoding: .utf8)
        let notes = UserReleaseNotes.parse(doc)
        check(notes.count == 15 && notes.first?.version == "v3.1.1" && notes.last?.version == "v1.0", "完整读取全部已发布历史版本，不受 Release 十条限制")
        check(!notes.contains { $0.date == "待发布" }, "待发布版本不进入应用日志或更新判断")
        check(notes.allSatisfy { !$0.items.isEmpty && $0.items.count <= 5 && $0.items.allSatisfy { $0.count <= 50 } }, "每版最多五条简短用户文案")
        check(!notes.flatMap(\.items).contains { $0.contains("后台用水监控") || $0.contains("单格开关") }, "iOS 不展示 Android 专属能力")
        let android = UserReleaseNotes.parse(doc, platform: "Android")
        check(android.count == 15 && android.flatMap(\.items).contains { $0.contains("后台用水监控") }, "Android 日志保留平台专属能力")
        check(!android.flatMap(\.items).contains { $0.contains("通知、扫码权限") }, "Android 不混入 iOS 适配记录")
        let sample = "<!-- linyu-release-notes:1 -->\n## v3.2.0 | 2026-11-05\n- 改善体验\n- 兼容新设备\n- [iOS] 精简提示\n## v3.3.0 | 待发布\n- 未发布\n"
        check(UserReleaseNotes.parse(sample).first?.items.count == 3, "普通优化与兼容条目完整保留，不靠新增修复关键词")
        check(UserReleaseNotes.parse("<html>error</html>").isEmpty, "远程错误页面不能覆盖离线日志")
        check(UserReleaseNotes.merge(preferred: [], fallback: notes) == notes, "失败刷新保留离线日志")
        check(UserReleaseNotes.merge(preferred: UserReleaseNotes.parse(sample), fallback: notes).count == notes.count + 1, "新增远程版本不丢失旧版本")
        check(!UserReleaseNotes.parse(sample).contains { $0.version == "v3.3.0" }, "样例中的待发布版本仍被排除")
        let crlf = doc.replacingOccurrences(of: "\n", with: "\r\n")
        check(UserReleaseNotes.parse(crlf) == notes, "Windows 换行不影响日志读取")
        let legacy = UserReleaseNote(version: "v3.1.0", date: "2026-09-30", items: ["支持 Android 8.0。 ", "消费 0.025 元。", "区分“结算中”。金额准确。"])
        check(legacy.text == "• 支持 Android 8.0\n• 消费 0.025 元\n• 区分“结算中”。金额准确", "旧缓存只去条目末尾句号，保留内部标点和小数点")
        check(notes.flatMap(\.items).allSatisfy { !$0.hasSuffix("。") }, "内置用户日志条目不带结尾句号")
        check(UserReleaseNotes.local(document: "broken", bundled: notes) == notes, "损坏缓存回退内置内容")
        check(UserReleaseNotes.local(document: sample, bundled: notes).count == 1, "有效远程全文替换缓存，不复活已删除版本")
        var refresh = ReleaseNotesRefreshPolicy()
        let now = Date(timeIntervalSince1970: 100)
        check(refresh.shouldRefresh(now: now, force: false), "启动首次进入自动刷新日志")
        refresh.finish(now: now, succeeded: false)
        check(!refresh.shouldRefresh(now: now.addingTimeInterval(1), force: false), "合并紧邻的生命周期请求")
        check(refresh.shouldRefresh(now: now.addingTimeInterval(6), force: false), "首次失败后再次进入可自动重试")
        refresh.finish(now: now, succeeded: true)
        check(refresh.shouldRefresh(now: now.addingTimeInterval(16), force: false), "成功后不永久锁定日志，可再次自动更新")
        check(refresh.shouldRefresh(now: now, force: true), "手动检查不受自动刷新间隔限制")
        var requested: [URL] = []
        let loaded = try await UserReleaseNotesLoader.load { request in
            let url = request.url!
            requested.append(url)
            check(request.cachePolicy == .reloadIgnoringLocalCacheData && request.value(forHTTPHeaderField: "Cache-Control") == "no-cache", "日志请求不直接沿用 HTTP 旧缓存")
            if url == UserReleaseNotes.remoteURL { throw URLError(.timedOut) }
            return (Data(sample.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        check(loaded == sample && requested == [UserReleaseNotes.remoteURL, UserReleaseNotes.fallbackURL], "原始文件地址超时后通过 GitHub API 拉取同一文档")
        var rejected = false
        do {
            _ = try await UserReleaseNotesLoader.load { request in
                (Data("<html>error</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        } catch { rejected = true }
        check(rejected, "两个地址都返回无效文档时禁止写入缓存")
        var cancellationRequests = 0
        do {
            _ = try await UserReleaseNotesLoader.load { _ in
                cancellationRequests += 1
                throw CancellationError()
            }
        } catch is CancellationError {} catch { check(false, "取消错误不能被转换为网络错误") }
        check(cancellationRequests == 1, "取消下载后不继续请求备用地址")
        if failures > 0 { fatalError("\(failures) release note checks failed") }
    }
}
