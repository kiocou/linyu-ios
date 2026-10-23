import SwiftUI

/// Release history is shared across visits to the user page.
@MainActor
private final class SoftwareReleaseStore: ObservableObject {
    static let shared = SoftwareReleaseStore()
    @Published private(set) var releases: [SoftwareRelease] = []
    @Published private(set) var checking = false
    @Published private(set) var checked = false
    @Published private(set) var failed = false
    private var checkTask: Task<Void, Never>?

    func check(force: Bool = false) async {
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
}

private struct SoftwareRelease: Decodable, Identifiable {
    let id: Int
    let tagName: String
    let body: String?
    let publishedAt: String?
    let draft: Bool
    let prerelease: Bool
    enum CodingKeys: String, CodingKey {
        case id, body, draft, prerelease
        case tagName = "tag_name", publishedAt = "published_at"
    }
}

@MainActor
struct SoftwareUpdateCard: View {
    @Environment(\.appColors) private var colors
    @Environment(\.openURL) private var openURL
    @ObservedObject private var releases = SoftwareReleaseStore.shared
    @State private var expandedID: Int?
    @State private var showAll = false

    private let tutorialURL = URL(string: "https://github.com/yehu-imei/Guides/blob/main/Tutorial/.ipa%E7%9A%84%E5%AE%89%E8%A3%85")!
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.1.0"
    }
    private var hasUpdate: Bool {
        guard let latest = releases.releases.first else { return false }
        return compareVersion(latest.tagName, currentVersion) == .orderedDescending
    }
    private var status: (String, Color) {
        if releases.checking || !releases.checked { return ("正在检测更新…", colors.textSecondary) }
        if releases.failed { return ("检测失败（多为网络原因）", colors.warning) }
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
                if !releases.releases.isEmpty {
                    Divider().overlay(colors.border).padding(.top, 14).padding(.bottom, 10)
                    Text("更新日志").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.textPrimary).padding(.bottom, 2)
                    ForEach(showAll ? releases.releases : Array(releases.releases.prefix(3))) { release in
                        releaseRow(release)
                    }
                    if releases.releases.count > 3 {
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
                    Text("看教程").font(.system(size: 14)).foregroundStyle(colors.accent)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.border))
                }.buttonStyle(InstantButtonStyle()).padding(.top, 10)
            }
        }
        .task { await releases.check() }
    }

    private func releaseRow(_ release: SoftwareRelease) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expandedID = expandedID == release.id ? nil : release.id } label: {
                HStack(spacing: 6) {
                    Text(release.tagName).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    if compareVersion(release.tagName, currentVersion) == .orderedSame {
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
                Text(notes(release.body)).font(.system(size: 12)).foregroundStyle(colors.textSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                if let date = release.publishedAt {
                    Text(String(date.prefix(10))).font(.system(size: 11))
                        .foregroundStyle(colors.textSecondary.opacity(0.7)).padding(.bottom, 6)
                }
                Divider().overlay(colors.border)
            }
        }
    }

    private func notes(_ body: String?) -> String {
        let source = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "本版本未填写更新详情。" }
        // Match Android's release highlights, omitting download/install sections.
        var highlights: [String] = []
        var keeping = false
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                keeping = ["新增", "功能", "修复", "bug"].contains { title.localizedCaseInsensitiveContains($0) }
                if keeping { highlights.append(title) }
            } else if keeping {
                highlights.append(raw)
            }
        }
        let content = highlights.isEmpty ? source : highlights.joined(separator: "\n")
        return content.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
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
