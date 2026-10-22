import SwiftUI
import UIKit

/// 运行日志查看与导出
struct LogView: View {
    @ObservedObject private var log = AppLog.shared
    @Environment(\.dismiss) private var dismiss

    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var note = ""

    enum Filter: String, CaseIterable {
        case all = "全部"
        case warn = "警告"
        case error = "错误"
    }

    private var visible: [LogLine] {
        var list = log.lines
        switch filter {
        case .all: break
        case .warn: list = list.filter { $0.level == .warn }
        case .error: list = list.filter { $0.level == .error }
        }
        let kw = searchText.trimmingCharacters(in: .whitespaces)
        if !kw.isEmpty {
            list = list.filter {
                $0.message.localizedCaseInsensitiveContains(kw)
                    || ($0.detail ?? "").localizedCaseInsensitiveContains(kw)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("过滤", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if visible.isEmpty {
                Spacer()
                Text("没有日志")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(visible) { line in
                            row(line).id(line.id)
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "搜索日志内容")
                    .onAppear {
                        if let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            VStack(spacing: 8) {
                TextField("备注（可选，比如「105房开不了阀」）", text: $note)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    Button {
                        exportLog()
                    } label: {
                        Label("导出日志", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        log.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
        }
        .navigationTitle("运行日志（\(log.lines.count)）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
    }

    private func row(_ l: LogLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(l.level.rawValue)
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(levelColor(l.level))
                Text(l.timeText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(l.message)
                    .font(.caption)
                    .lineLimit(3)
            }
            if let d = l.detail, !d.isEmpty {
                Text(d)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func levelColor(_ l: LogLine.Level) -> Color {
        switch l {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func exportLog() {
        guard let url = log.exportFile(note: note) else { return }
        exportURL = url
        showShare = true
    }
}
