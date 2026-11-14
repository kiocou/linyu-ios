import SwiftUI

/// Release history is shared across visits to the user page.
@MainActor
private final class SoftwareReleaseStore: ObservableObject {
    static let shared = SoftwareReleaseStore()
    @Published private(set) var releases: [SoftwareRelease] = []
    @Published private(set) var notes: [UserReleaseNote]
    @Published private(set) var checking = false
    @Published private(set) var checked = false
    @Published private(set) var failed = false
    private var checkTask: Task<Void, Never>?
    private var notesTask: Task<Void, Never>?
    private var notesRefresh = ReleaseNotesRefreshPolicy()
    private static let notesCacheKey = "userReleaseNotes.v1"

    private init() {
        notes = UserReleaseNotes.local(document: UserDefaults.standard.string(forKey: Self.notesCacheKey) ?? "",
                                      bundled: UserReleaseNotes.bundled)
    }

    func check(force: Bool = false) async {
        // 版本结果可以复用，但每次进入卡片仍应独立检查日志，失败也能重试。
        async let notesFetch: Void = refreshNotes(force: force)
        await checkVersion(force: force)
        await notesFetch
    }

    private func checkVersion(force: Bool) async {
        if let checkTask { await checkTask.value; return }
        guard force || !checked else { return }
        let task = Task { @MainActor in
            defer { self.checkTask = nil }
            await self.fetch()
        }
        checkTask = task
        await task.value
    }

    private func fetch() async {
        checking = true
        failed = false
        defer { checking = false }
        do {
            let url = URL(string: "https://api.github.com/repos/yehu-imei/linyu/releases?per_page=30")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let fetched = try JSONDecoder().decode([SoftwareRelease].self, from: data)
                .filter { !$0.draft && !$0.prerelease && !$0.tagName.isEmpty }
            guard !fetched.isEmpty else { throw URLError(.cannotParseResponse) }
            releases = fetched
            checked = true
        } catch {
            // Cancellation on leaving the page must not poison the session cache.
            guard !Task.isCancelled else { return }
            checked = true
            failed = true
            AppLog.shared.w("检查更新失败：\(error.localizedDescription)")
        }
    }

    func refreshNotes(force: Bool = false) async {
        if let notesTask { await notesTask.value; return }
        guard notesRefresh.shouldRefresh(now: Date(), force: force) else { return }
        let task = Task { @MainActor in
            defer { self.notesTask = nil }
            do {
                let document = try await UserReleaseNotesLoader.load { try await URLSession.shared.data(for: $0) }
                let parsed = UserReleaseNotes.parse(document)
                self.notes = parsed
                UserDefaults.standard.set(document, forKey: Self.notesCacheKey)
                self.notesRefresh.finish(now: Date(), succeeded: true)
                AppLog.shared.i("用户更新日志已刷新并缓存：\(parsed.count) 个版本，文档 \(document.utf8.count) 字节")
            } catch {
                self.notesRefresh.finish(now: Date(), succeeded: false)
                AppLog.shared.w("用户更新日志刷新失败，保留本地内容；下次进入时重试")
            }
        }
        notesTask = task
        await task.value
    }
}

private struct SoftwareRelease: Decodable, Identifiable {
    let id: Int
    let tagName: String
    let publishedAt: String?
    let draft: Bool
    let prerelease: Bool
    enum CodingKeys: String, CodingKey {
        case id, draft, prerelease
        case tagName = "tag_name", publishedAt = "published_at"
    }
}

@MainActor
struct SoftwareUpdateCard: View {
    @Environment(\.appColors) private var colors
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var releases = SoftwareReleaseStore.shared
    @State private var expandedID: String?
    @State private var showAll = false

    private let tutorialURL = URL(string: "https://github.com/yehu-imei/Guides/blob/main/Tutorial/.ipa%E7%9A%84%E5%AE%89%E8%A3%85.md")!
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.1.1"
    }
    private var hasUpdate: Bool {
        guard let latest = releases.releases.first else { return false }
        return compareVersion(latest.tagName, currentVersion) == .orderedDescending
    }
    private var status: (String, Color) {
        if releases.checking || !releases.checked { return ("正在检测更新…", colors.textSecondary) }
        if releases.failed { return ("检查更新失败，请重试", colors.warning) }
        if hasUpdate { return ("发现新版本 \(releases.releases.first?.tagName ?? "")", colors.accent) }
        return ("当前已是最新版本", colors.success)
    }

    var body: some View {
        BaseCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("应用信息").font(.system(size: 16, weight: .semibold)).foregroundStyle(colors.textPrimary)
                Text("当前版本 \(currentVersion)")
                    .font(.system(size: 13)).foregroundStyle(colors.textSecondary).padding(.top, 4)
                Text(status.0).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(status.1).padding(.top, 8)
                if !releases.notes.isEmpty {
                    Divider().overlay(colors.border).padding(.top, 14).padding(.bottom, 10)
                    Text("更新日志").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.textPrimary).padding(.bottom, 2)
                    ForEach(showAll ? releases.notes : Array(releases.notes.prefix(3))) { release in
                        releaseRow(release)
                    }
                    if releases.notes.count > 3 {
                        Button { showAll.toggle() } label: {
                            Text(showAll ? "收起" : "展开全部")
                                .font(.system(size: 12)).foregroundStyle(colors.accent)
                                .frame(maxWidth: .infinity).frame(minHeight: 40)
                        }.buttonStyle(InstantButtonStyle())
                    }
                }
                Button { Task { await releases.check(force: true) } } label: {
                    Text(releases.checking ? "检查中..." : "检查更新")
                        .font(.system(size: 14)).frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle(colors: colors, radius: 12, height: 44))
                .disabled(releases.checking).padding(.top, 14)
                Button { openURL(tutorialURL) } label: {
                    Text("安装教程").font(.system(size: 14)).foregroundStyle(colors.accent)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.border))
                }.buttonStyle(InstantButtonStyle()).padding(.top, 10)
            }
        }
        .task { await releases.check() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await releases.refreshNotes() } }
        }
    }

    private func releaseRow(_ release: UserReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expandedID = expandedID == release.id ? nil : release.id } label: {
                HStack(spacing: 6) {
                    Text(release.version).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    if compareVersion(release.version, currentVersion) == .orderedSame {
                        Text("当前").font(.system(size: 10)).foregroundStyle(colors.success)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(colors.success.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    Image(systemName: expandedID == release.id ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13)).foregroundStyle(colors.textSecondary)
                }.frame(minHeight: 40).contentShape(Rectangle())
            }.buttonStyle(InstantButtonStyle())
            if expandedID == release.id {
                Text(release.text).font(.system(size: 12)).foregroundStyle(colors.textSecondary)
                    .lineSpacing(3)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                Text(release.date).font(.system(size: 11))
                    .foregroundStyle(colors.textSecondary.opacity(0.7)).padding(.bottom, 6)
            }
        }
    }

    private func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ value: String) -> [Int] {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let left = parts(lhs), right = parts(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }
}
