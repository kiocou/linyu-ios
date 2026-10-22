import SwiftUI
import CoreBluetooth

/// 首页：发现设备 → 开阀 → 用水 → 关阀结算
struct HomeView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var scanner = BLEScanner()
    @StateObject private var flow = ShowerFlow()

    /// snCode → 台账信息
    @State private var resolved: [String: DeviceInfo] = [:]
    /// 正在查台账的 snCode，避免重复请求
    @State private var resolving: Set<String> = []
    @State private var errorText = ""
    @State private var showLog = false

    /// 只显示能解析出 snCode 的设备（广播格式已实测确认）
    private var candidates: [DiscoveredPeripheral] {
        scanner.devices.filter { $0.parsedSnCode != nil }
    }

    var body: some View {
        List {
            if let order = flow.activeOrder {
                Section {
                    inUseCard(order)
                }
            }

            if case .failed(let msg) = flow.stage {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.footnote)
                    }
                }
            }

            Section {
                scanStatusRow
            }

            Section {
                if candidates.isEmpty {
                    emptyHint
                } else {
                    ForEach(candidates) { d in
                        deviceRow(d)
                    }
                }
            } header: {
                HStack {
                    Text("附近热水表（\(candidates.count)）")
                    Spacer()
                    if flow.stage == .inUse { Text("用水时不能开新单").font(.caption2).foregroundStyle(.orange) }
                }
            }

            Section {
                Button {
                    flow.reset()
                    scanner.start()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }

                Button {
                    showLog = true
                } label: {
                    Label("运行日志", systemImage: "doc.text.magnifyingglass")
                }

                Button(role: .destructive) {
                    flow.reset()
                    session.logout()
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !session.displayName.isEmpty {
                        Text(session.displayName)
                    }
                    Text("projectId \(session.projectId) · \(session.telephone)")
                        .font(.caption2)
                }
            }
        }
        .navigationTitle("淋浴")
        .sheet(isPresented: $showLog) {
            NavigationStack { LogView() }
        }
        .task {
            scanner.start()
        }
        .onChange(of: scanner.devices) { list in
            // 新出现的设备去查台账
            for d in list {
                guard let sn = d.parsedSnCode else { continue }
                guard resolved[sn] == nil, !resolving.contains(sn) else { continue }
                resolving.insert(sn)
                Task { await resolveDevice(sn) }
            }
        }
        .onDisappear { scanner.stop() }
    }

    // MARK: - 子视图

    private var scanStatusRow: some View {
        HStack {
            Circle()
                .fill(scanner.isScanning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(scanner.stateText)
                .font(.subheadline)
            Spacer()
            Text(flow.stage.text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有扫到热水表").font(.subheadline.weight(.medium))
            Text("把手机拿到热水器旁边——水表广播间隔很短，通常几秒内就能出现。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func inUseCard(_ order: ActiveOrder) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(order.device.displayName)
                        .font(.headline)
                    Text("SN \(order.snCode)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "drop.fill")
                    .foregroundStyle(.blue)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatted(order.elapsedSeconds))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("已用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let pre = order.preDeductMoney, pre > 0 {
                Text("已预扣 ¥\(String(format: "%.2f", pre))，按实际用量结算")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task { await flow.close() }
            } label: {
                HStack {
                    Spacer()
                    if flow.stage == .closing || flow.stage == .collecting || flow.stage == .uploading {
                        ProgressView().tint(.white)
                    } else {
                        Text("结束用水").font(.headline)
                    }
                    Spacer()
                }
                .frame(height: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(flow.stage == .closing || flow.stage == .collecting || flow.stage == .uploading)
        }
        .padding(.vertical, 6)
    }

    private func deviceRow(_ d: DiscoveredPeripheral) -> some View {
        let sn = d.parsedSnCode ?? ""
        let info = resolved[sn]
        let name = info?.displayName ?? "SN \(sn)"
        let busyThis = flow.stage == .connecting || flow.stage == .querying
            || flow.stage == .requestingRate || flow.stage == .writingRate

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(sn)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text("\(d.rssi) dBm")
                        .font(.caption2.monospaced())
                        .foregroundStyle(rssiColor(d.rssi))
                }
                if info == nil && resolving.contains(sn) {
                    Text("查询台账中…").font(.caption2).foregroundStyle(.tertiary)
                } else if info == nil {
                    Text("台账里没有这台（不能开阀）").font(.caption2).foregroundStyle(.orange)
                }
            }

            Spacer()

            Button {
                open(d, info: info)
            } label: {
                if busyThis {
                    ProgressView()
                } else {
                    Text("开水").font(.footnote.weight(.medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(info == nil || flow.activeOrder != nil || flow.stage != .idle && flow.stage != .done
                      && !isFailed(flow.stage))
        }
        .padding(.vertical, 4)
    }

    // MARK: - 动作

    private func isFailed(_ s: ShowerFlow.Stage) -> Bool {
        if case .failed = s { return true }
        return false
    }

    private func resolveDevice(_ sn: String) async {
        do {
            let data = try await ApiClient.get("/device/info/mac", query: ["macAddress": sn], tag: "deviceInfo")
            let resp = try ApiClient.decode(DeviceInfo.self, from: data, path: "deviceInfo")
            if let info = resp.data {
                resolved[sn] = info
                AppLog.shared.i("台账命中 \(sn) → \(info.displayName)（deviceId=\(info.deviceId ?? -1)）")
            } else {
                AppLog.shared.w("台账查不到 \(sn)（success=true 但 data 为空）")
            }
        } catch {
            AppLog.shared.w("查台账失败 \(sn)：\(error.localizedDescription)")
        }
        resolving.remove(sn)
    }

    private func open(_ d: DiscoveredPeripheral, info: DeviceInfo?) {
        guard let info, let sn = d.parsedSnCode else { return }
        guard let p = scanner.peripheral(for: d.id) else {
            errorText = "拿不到设备引用，请重新扫描"
            return
        }
        scanner.stop()
        AppLog.shared.i("点击开水：\(info.displayName)")

        Task {
            await flow.open(device: info, peripheral: p)
            // 开阀结束（成功或失败）后重新开始扫描
            if flow.activeOrder == nil {
                scanner.start()
            }
        }
    }

    private func formatted(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case ..<(-80): return .red
        case ..<(-65): return .orange
        default: return .green
        }
    }
}
