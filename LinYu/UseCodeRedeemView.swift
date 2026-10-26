import SwiftUI

struct UseCodeRedeemView: View {
    @EnvironmentObject private var store: AppDataStore
    @Environment(\.appColors) private var colors
    let onDismiss: () -> Void
    var onRedeemed: () -> Void = {}
    @State private var candidate = ""
    @State private var expires = Date.distantPast
    @State private var remainTimes: Int?
    @State private var busy = false
    @State private var claiming = false
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
                            .font(.system(size: 14)).foregroundStyle(colors.textPrimary)
                    } else {
                        if let current = store.useCode?.useCode, !current.isEmpty {
                            HStack {
                                Text("当前使用码")
                                Spacer()
                                Text(current).tracking(1)
                            }.font(.system(size: 12)).padding(.bottom, 2)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(expires.timeIntervalSince(context.date)))
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 4) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("领取后替换为").font(.system(size: 12))
                                        Group {
                                            if candidate.isEmpty {
                                                Text("— — — — — — — —").foregroundColor(colors.textSecondary)
                                            } else {
                                                Text(String(candidate.dropLast(3)))
                                                    .foregroundColor(seconds == 0 ? colors.textSecondary : colors.textPrimary)
                                                + Text(String(candidate.suffix(3)))
                                                    .foregroundColor(seconds == 0 ? colors.textSecondary : colors.accent)
                                            }
                                        }.font(.system(size: 24, weight: .black)).tracking(3)
                                            .lineLimit(1).minimumScaleFactor(0.65)
                                    }
                                    Spacer(minLength: 0)
                                    Button { Task { await generate() } } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.clockwise").font(.system(size: 18))
                                            Text(busy && !claiming ? "换码中" : (candidate.isEmpty ? "获取" : "换一个"))
                                                .font(.system(size: 13))
                                        }.foregroundStyle(colors.accent).frame(minHeight: 44)
                                    }.disabled(busy)
                                }
                                if !candidate.isEmpty {
                                    Text(seconds == 0 ? "已超时，请重新换一个" : String(format: "请在 %d:%02d 内领取", seconds / 60, seconds % 60))
                                        .font(.system(size: 11))
                                        .foregroundStyle(seconds == 0 ? colors.danger : colors.textSecondary)
                                }
                                if let remainTimes {
                                    Text("今日还能换 \(remainTimes) 次").font(.system(size: 11))
                                }
                            }
                        }
                        if let errorText { Text(errorText).font(.system(size: 12)).foregroundStyle(colors.danger) }
                    }
                }.foregroundStyle(colors.textSecondary)
            } actions: {
                DialogTextButton(title: unavailable && eligibilityLoaded ? "知道了" : "取消", color: colors.accent, enabled: !busy) { onDismiss() }
                if eligibilityLoaded && !unavailable {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        DialogTextButton(title: claiming ? "领取中…" : "确定领取", color: colors.accent,
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
        // Android 使用卡片已有的领取资格，打开弹窗不再额外等一次账号查询。
        if store.useCodeLoaded { eligibilityLoaded = true }
        else { eligibilityLoaded = await store.loadUseCode() }
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
            let result = try await store.generateUseCode()
            guard let code = result.useCode, !code.isEmpty else {
                errorText = "换码失败，请重试"; return
            }
            candidate = code
            remainTimes = result.remainTimes
            expires = Date().addingTimeInterval(180)
        } catch is CancellationError { return }
        catch { errorText = "换码失败，请重试" }
    }

    private func redeem() async {
        guard !busy, !candidate.isEmpty, expires > Date() else { return }
        busy = true
        claiming = true
        errorText = nil
        defer { busy = false; claiming = false }
        do {
            try await store.claimUseCode(candidate)
            onRedeemed()
            onDismiss()
        } catch is CancellationError { return }
        catch { errorText = "领取失败，请重试" }
    }
}
