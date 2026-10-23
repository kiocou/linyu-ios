import SwiftUI

struct LogView: View {
    let onBack: () -> Void
    @ObservedObject private var log = AppLog.shared
    @Environment(\.appColors) private var colors
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var exportFailed = false

    private enum Filter: String, CaseIterable {
        case all = "全部", warn = "警告", error = "错误"
    }

    private var visible: [LogLine] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return log.lines.filter { line in
            let matchesLevel = filter == .all || (filter == .warn && line.level == .warn)
                || (filter == .error && line.level == .error)
            return matchesLevel && (keyword.isEmpty
                || line.message.localizedCaseInsensitiveContains(keyword)
                || (line.detail ?? "").localizedCaseInsensitiveContains(keyword))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("运行日志 (\(log.lines.count))")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(colors.textPrimary)
                Spacer()
                Button(action: onBack) {
                    Image(systemName: "xmark").font(.system(size: 18))
                        .foregroundStyle(colors.textSecondary).frame(width: 44, height: 44)
                }.accessibilityLabel("关闭")
            }
            .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 8)
            Divider().overlay(colors.border)
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { item in
                    Button { filter = item } label: {
                        Text(item.rawValue).font(.system(size: 12))
                            .foregroundStyle(filter == item ? colors.onAccent : colors.textSecondary)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(filter == item ? colors.accent : colors.surfaceVariant)
                            .clipShape(Capsule())
                    }.accessibilityAddTraits(filter == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).padding(.top, 10)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(colors.textSecondary)
                TextField("搜索日志内容", text: $searchText)
                    .font(.system(size: 13)).foregroundStyle(colors.textPrimary)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(colors.textSecondary)
                    }.accessibilityLabel("清除搜索")
                }
            }
            .padding(10).background(colors.surfaceVariant).clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 14).padding(.vertical, 8)
            if visible.isEmpty {
                Text(log.lines.isEmpty ? "暂无日志" : "暂无匹配日志")
                    .font(.system(size: 14)).foregroundStyle(colors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { line in
                            Text(formatted(line)).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(colors.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 8)
                }.scrollDismissesKeyboard(.interactively)
            }
            Divider().overlay(colors.border)
            HStack(spacing: 12) {
                Button { log.clear() } label: {
                    Text("清空").font(.system(size: 14)).foregroundStyle(colors.accent)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.border))
                }
                Button { exportLog() } label: {
                    Text("导出/分享").font(.system(size: 14)).frame(maxWidth: .infinity)
                }.buttonStyle(AccentButtonStyle(colors: colors, radius: 12, height: 44))
            }.padding(16)
            if exportFailed {
                Text("导出日志失败，请重试").font(.system(size: 12))
                    .foregroundStyle(colors.warning).padding(.bottom, 12)
            }
        }
        .background(colors.solidSurface)
        .sheet(isPresented: $showShare) {
            if let url = exportURL { ShareSheet(items: [url]) }
        }
    }

    private func formatted(_ line: LogLine) -> String {
        var text = "[\(line.timeText)] [\(line.level.rawValue)] \(line.message)"
        if let detail = line.detail, !detail.isEmpty { text += "\n  " + detail }
        return text
    }

    private func exportLog() {
        guard let url = log.exportFile() else { exportFailed = true; return }
        exportFailed = false
        exportURL = url
        showShare = true
    }
}
