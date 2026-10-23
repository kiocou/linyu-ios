import SwiftUI
import Combine

@MainActor
final class UserPresentation: ObservableObject {
    enum Page { case background, log }
    enum Dialog { case phone, password, useCode, room }
    @Published var page: Page?
    @Published var dialog: Dialog?
}

struct UserDialogs: View {
    @EnvironmentObject private var presentation: UserPresentation
    @EnvironmentObject private var store: AppDataStore
    @Environment(\.appColors) private var colors
    @ObservedObject var scanner: BLEScanner
    let onRoomSelected: (String) -> Void
    private var rooms: [String] {
        Array(Set(scanner.devices.compactMap { device in
            guard let sn = device.parsedSnCode, let name = store.deviceInfos[sn]?.deviceName else { return nil }
            return DeviceInfo.roomKey(name)
        })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var body: some View {
        switch presentation.dialog {
        case .phone:
            ChangePhoneDialog(currentPhone: Session.shared.telephone) { presentation.dialog = nil }
        case .password:
            ChangePasswordDialog(currentPhone: Session.shared.telephone) { presentation.dialog = nil }
        case .useCode:
            UseCodeRedeemView(onDismiss: { presentation.dialog = nil })
        case .room:
            DialogScrim(onTapOutside: { presentation.dialog = nil }) {
                AlertCard(title: "选择设备位置", titleAlign: .leading) {
                    if rooms.isEmpty {
                        Text("附近暂无设备").foregroundStyle(colors.textSecondary)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(rooms, id: \.self) { key in
                                    Button {
                                        Prefs.boundRoom = key
                                        presentation.dialog = nil
                                        onRoomSelected(key)
                                    } label: {
                                        TailEllipsisText(text: key, fontSize: 14, color: colors.textPrimary)
                                            .frame(minHeight: 44)
                                    }.buttonStyle(InstantButtonStyle())
                                }
                            }
                        }.frame(height: min(CGFloat(rooms.count) * 44, 210))
                    }
                } actions: {
                    DialogTextButton(title: "关闭", color: colors.accent) { presentation.dialog = nil }
                }
            }
        case nil: EmptyView()
        }
    }
}
