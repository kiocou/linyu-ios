import SwiftUI

// MARK: - 修改密码

/// 修改密码 —— 对照 Android `UserScreen.ChangePasswordDialog`。
///
/// 两条路（Android 注释原话）：
/// - **知道当前密码**：`/user/password/update`，要 `oldPassword`
/// - **不知道 / 从没设过**：`/user/password/forget`，只用手机验证码，**不要旧密码**
///
/// 第二条不能省：短信验证码注册的账号根本没有密码可填，
/// 少了它「修改密码」对这些人就是个死按钮。
struct ChangePasswordDialog: View {
    @Environment(\.appColors) private var colors
    let currentPhone: String
    let onDismiss: () -> Void

    /// false = 知道当前密码；true = 走短信验证码
    @State private var smsMode = false
    @State private var oldPwd = ""
    @State private var newPwd = ""
    @State private var confirmPwd = ""
    @State private var code = ""
    /// 验证码发给当前绑定手机号，与认证参数保持一致。
    @State private var phone: String
    @State private var sending = false
    @State private var countdown = 0
    @State private var submitting = false
    @State private var errorText: String?

    init(currentPhone: String, onDismiss: @escaping () -> Void) {
        self.currentPhone = currentPhone
        self.onDismiss = onDismiss
        _phone = State(initialValue: currentPhone)
    }

    private var canSubmit: Bool {
        if smsMode {
            return phone.count == 11 && code.count >= 4 && newPwd.count >= 6 && newPwd == confirmPwd
        }
        return oldPwd.count >= 6 && newPwd.count >= 6 && newPwd == confirmPwd
    }

    var body: some View {
        DialogScrim(onTapOutside: { if !submitting { onDismiss() } }) {
            AlertCard(title: "修改密码", titleAlign: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    // 模式切换
                    Button {
                        smsMode.toggle()
                        errorText = nil
                    } label: {
                        Text(smsMode ? "使用当前密码修改" : "使用验证码修改")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.accent)
                    }
                    .buttonStyle(InstantButtonStyle())
                    .disabled(submitting || sending)

                    if smsMode {
                        Text("当前手机号：\(currentPhone)")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.textSecondary)

                        dialogField("手机号", text: $phone, keyboard: .numberPad).disabled(true)

                        HStack(spacing: 10) {
                            dialogField("验证码", text: $code, keyboard: .numberPad)
                            Button {
                                Task { await sendCode() }
                            } label: {
                                Text(countdown > 0 ? "\(countdown)s" : "发送")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .frame(width: 86, height: 50)
                                    .background(canSendCode ? colors.accent : colors.accent.opacity(0.45))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(InstantButtonStyle())
                            .disabled(!canSendCode)
                        }
                    } else {
                        dialogField("当前密码", text: $oldPwd, keyboard: .default, secured: true)
                    }

                    dialogField("新密码", text: $newPwd, keyboard: .default, secured: true)
                    dialogField("确认新密码", text: $confirmPwd, keyboard: .default, secured: true)

                    if newPwd != confirmPwd, !confirmPwd.isEmpty {
                        Text("两次输入的新密码不一致")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.danger)
                    }

                    if let e = errorText {
                        Text(e)
                            .font(.system(size: 12))
                            .foregroundStyle(colors.danger)
                    }
                }
                .disabled(submitting)
            } actions: {
                DialogTextButton(title: "取消", color: colors.accent) {
                    if !submitting { onDismiss() }
                }
                DialogTextButton(
                    title: submitting ? "提交中…" : "确定",
                    color: colors.accent
                ) {
                    Task { await submit() }
                }
                .disabled(!canSubmit || submitting)
            }
        }
        .interactiveDismissDisabled(submitting)
    }

    private var canSendCode: Bool { !sending && countdown == 0 && phone.count == 11 }

    private func sendCode() async {
        sending = true
        errorText = nil
        defer { sending = false }
        do {
            // ⚠️ typeId = 2 才是「改密码」的验证码（照搬 Android 注释）
            try await AuthService.sendSmsCode(phone: phone, typeId: 2)
            countdown = 60
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                countdown -= 1
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func submit() async {
        guard canSubmit, !submitting else { return }
        submitting = true
        errorText = nil
        defer { submitting = false }
        do {
            // 密码用和登录同一套加密：MD5 取后 10 位大写
            let enc = AuthService.encryptPassword(newPwd)
            let raw: Data
            if smsMode {
                raw = try await ApiClient.post(
                    "/user/password/forget",
                    form: ["password": enc, "code": code],
                    tag: "forgetPassword"
                )
            } else {
                raw = try await ApiClient.post(
                    "/user/password/update",
                    form: [
                        "oldPassword": AuthService.encryptPassword(oldPwd),
                        "password": enc
                    ],
                    tag: "updatePassword"
                )
            }
            _ = try ApiClient.decode(EmptyData.self, from: raw, path: "changePassword")
            SavedCredential.save(phone: currentPhone, password: newPwd)
            onDismiss()
        } catch {
            errorText = "修改失败：\(error.localizedDescription)"
        }
    }

    private func dialogField(
        _ title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType,
        secured: Bool = false
    ) -> some View {
        Group {
            if secured {
                SecureField(title, text: text)
            } else {
                TextField(title, text: text)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(colors.textPrimary)
        .keyboardType(keyboard)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(.horizontal, 12)
        .frame(height: 50)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(colors.border, lineWidth: 1)
        )
    }
}

// MARK: - 更换手机号

/// 更换手机号 —— 对照 Android `UserScreen.ChangePhoneDialog`。
struct ChangePhoneDialog: View {
    @Environment(\.appColors) private var colors
    let currentPhone: String
    let onDismiss: () -> Void

    @State private var newPhone = ""
    @State private var code = ""
    @State private var sending = false
    @State private var countdown = 0
    @State private var submitting = false
    @State private var errorText: String?

    private var canSubmit: Bool {
        newPhone.count == 11 && !code.isEmpty && !submitting
    }

    var body: some View {
        DialogScrim(onTapOutside: { if !submitting { onDismiss() } }) {
            AlertCard(title: "更换手机号", titleAlign: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    // ⚠️ 验证码发到**新**手机号（typeId = 5），不是当前绑定的那个。
                    // 抓包实测：`telephone=新号&typeId=5`，旧号只作为认证参数出现。
                    // 发到旧号用户根本收不到，会一直提示验证码错误。
                    Text("当前手机号：\(currentPhone)")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)

                    field("新手机号", text: $newPhone, keyboard: .numberPad)

                    HStack(spacing: 10) {
                        field("验证码", text: $code, keyboard: .numberPad)
                        Button {
                            Task { await sendCode() }
                        } label: {
                            Text(countdown > 0 ? "\(countdown)s" : "发送")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(width: 86, height: 50)
                                .background(canSend ? colors.accent : colors.accent.opacity(0.45))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(InstantButtonStyle())
                        .disabled(!canSend)
                    }

                    if let e = errorText {
                        Text(e)
                            .font(.system(size: 12))
                            .foregroundStyle(colors.danger)
                    }
                }
                .disabled(submitting)
            } actions: {
                DialogTextButton(title: "取消", color: colors.accent) {
                    if !submitting { onDismiss() }
                }
                DialogTextButton(
                    title: submitting ? "提交中…" : "确定",
                    color: colors.accent
                ) {
                    Task { await submit() }
                }
                .disabled(!canSubmit)
            }
        }
        .interactiveDismissDisabled(submitting)
    }

    private var canSend: Bool { !sending && countdown == 0 && newPhone.count == 11 }

    private func sendCode() async {
        sending = true
        errorText = nil
        defer { sending = false }
        do {
            // ⚠️ typeId = 5 = 发到**新**号的换绑验证码
            try await AuthService.sendSmsCode(phone: newPhone, typeId: 5)
            countdown = 60
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                countdown -= 1
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func submit() async {
        guard canSubmit, !submitting else { return }
        submitting = true
        errorText = nil
        defer { submitting = false }
        do {
            let raw = try await ApiClient.post(
                "/user/phone/update",
                form: ["newTelephone": newPhone, "code": code],
                tag: "updatePhone"
            )
            _ = try ApiClient.decode(EmptyData.self, from: raw, path: "updatePhone")
            SavedCredential.clear()
            // 认证参数里的 telephone 也得跟着换，否则后续请求还在用旧号
            Session.shared.updateTelephone(newPhone)
            onDismiss()
        } catch {
            errorText = "更换失败：\(error.localizedDescription)"
        }
    }

    private func field(
        _ title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType
    ) -> some View {
        TextField(title, text: text)
            .font(.system(size: 14))
            .foregroundStyle(colors.textPrimary)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(height: 50)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(colors.border, lineWidth: 1)
            )
    }
}
