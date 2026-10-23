import SwiftUI

private struct GeneratedUseCode: Decodable {
    let useCode: String?
    let remainTimes: Int?
}

struct UseCodeRedeemView: View {
    @EnvironmentObject private var store: AppDataStore
    @Environment(\.appColors) private var colors
    let onDismiss: () -> Void
    @State private var candidate = ""
    @State private var expires = Date.distantPast
    @State private var remainTimes: Int?
    @State private var busy = false
    @State private var errorText: String?
    @State private var checking = true
    @State private var eligibilityLoaded = false
    @State private var retryToken = 0
    private var unavailable: Bool { store.useCode?.resetAvailability == 0 }

    private var title: String {
        eligibilityLoaded && unavailable ? "无法领取" : (store.useCode?.useCode?.isEmpty == false ? "重新领取使用码" : "领取使用码")
    }

    var body: some View {
        DialogScrim(onTapOutside: { if !busy { onDismiss() } }) {
            AlertCard(title: title, titleAlign: .leading) {
                VStack(alignment: .leading, spacing: 12) {
                    if checking {
                        ProgressView("加载中...")
                    } else if !eligibilityLoaded {
                        Text("获取失败，请重试")
                        Button("重试") { retryToken += 1 }
                    } else if unavailable {
                        Text(store.useCode?.resetAvailabilityWarMark ?? "1天只能领取一次使用码")
                    } else {
                        if let current = store.useCode?.useCode {
                            Text("当前使用码：\(current)").font(.system(size: 13))
                        }
                        Text("领取后替换为").font(.system(size: 13))
                        Text(candidate.isEmpty ? "—" : candidate)
                            .font(.system(size: 28, weight: .bold)).tracking(4)
                            .foregroundStyle(colors.accent)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(expires.timeIntervalSince(context.date)))
                            if !candidate.isEmpty {
                                Text(seconds == 0 ? "已超时，请重新换一个" : String(format: "请在 %d:%02d 内领取", seconds / 60, seconds % 60))
                                    .font(.system(size: 12))
                            }
                        }
                        if let remainTimes { Text("今日还能换 \(remainTimes) 次").font(.system(size: 12)) }
                        Button(busy ? "换码中" : (candidate.isEmpty ? "获取" : "换一个")) {
                            Task { await generate() }
                        }.disabled(busy || remainTimes == 0)
                        if let errorText { Text(errorText).font(.system(size: 12)).foregroundStyle(colors.danger) }
                    }
                }.foregroundStyle(colors.textSecondary)
            } actions: {
                DialogTextButton(title: unavailable && eligibilityLoaded ? "知道了" : "取消", color: colors.accent, enabled: !busy) { onDismiss() }
                if eligibilityLoaded && !unavailable {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        DialogTextButton(title: busy ? "领取中…" : "确定领取", color: colors.accent,
                            enabled: !busy && !candidate.isEmpty && expires > context.date) {
                            Task { await redeem() }
                        }
                    }
                }
            }
        }
        .buttonStyle(InstantButtonStyle())
        .task(id: retryToken) { await prepare() }
    }

    private func prepare() async {
        checking = true
        eligibilityLoaded = await store.loadUseCode(force: true)
        checking = false
        guard eligibilityLoaded, !unavailable, !Task.isCancelled else { return }
        await generate()
    }

    private func generate() async {
        guard !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let raw = try await ApiClient.post("/account/useCode/new/generate", form: [:], tag: "generateUseCode")
            let result = try ApiClient.decode(GeneratedUseCode.self, from: raw, path: "generateUseCode")
            guard let code = result.data?.useCode, !code.isEmpty else {
                errorText = "获取失败，请重试"; return
            }
            candidate = code
            remainTimes = result.data?.remainTimes
            expires = Date().addingTimeInterval(180)
        } catch { errorText = error.localizedDescription }
    }

    private func redeem() async {
        guard !busy, !candidate.isEmpty, expires > Date() else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let raw = try await ApiClient.post("/account/useCode/new/set", form: ["useCode": candidate], tag: "setUseCode")
            _ = try ApiClient.decode(EmptyData.self, from: raw, path: "setUseCode")
            store.acceptUseCode(candidate)
            await store.loadUseCode(force: true)
            onDismiss()
        } catch { errorText = error.localizedDescription }
    }
}
