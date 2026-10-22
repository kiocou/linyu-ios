import SwiftUI

/// 登录页
struct LoginView: View {
    @EnvironmentObject private var session: Session
    @State private var phone = ""
    @State private var password = ""
    @State private var smsCode = ""
    @State private var isSmsMode = false
    @State private var busy = false
    @State private var errorText = ""
    @State private var countdown = 0

    private var canSubmit: Bool {
        if phone.count != 11 { return false }
        return isSmsMode ? smsCode.count >= 4 : !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    Picker("登录方式", selection: $isSmsMode) {
                        Text("密码").tag(false)
                        Text("验证码").tag(true)
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 12) {
                        TextField("手机号", text: $phone)
                            .keyboardType(.numberPad)
                            .textContentType(.telephoneNumber)
                            .padding(14)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                        if isSmsMode {
                            HStack(spacing: 10) {
                                TextField("验证码", text: $smsCode)
                                    .keyboardType(.numberPad)
                                    .padding(14)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                                Button {
                                    sendCode()
                                } label: {
                                    Text(countdown > 0 ? "\(countdown)s" : "获取")
                                        .frame(width: 64, height: 48)
                                }
                                .buttonStyle(.bordered)
                                .disabled(busy || countdown > 0 || phone.count != 11)
                            }
                        } else {
                            SecureField("密码", text: $password)
                                .textContentType(.password)
                                .padding(14)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if busy {
                                ProgressView().tint(.white)
                            } else {
                                Text("登录").font(.headline)
                            }
                            Spacer()
                        }
                        .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !canSubmit)

                    Text("登录信息只保存在本机钥匙串（Keychain），不会上传。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)

                    Spacer(minLength: 40)
                }
                .padding(24)
            }
            .navigationBarHidden(true)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("🚿").font(.system(size: 56))
            Text("淋浴").font(.largeTitle.bold())
            Text("趣智校园第三方客户端 · iOS")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 32)
        .padding(.bottom, 8)
    }

    // MARK: - 动作

    private func sendCode() {
        guard phone.count == 11 else { return }
        busy = true
        errorText = ""
        Task {
            do {
                try await AuthService.sendSmsCode(phone: phone)
                busy = false
                startCountdown()
            } catch {
                busy = false
                errorText = error.localizedDescription
            }
        }
    }

    private func startCountdown() {
        countdown = 60
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countdown <= 1 {
                t.invalidate()
                countdown = 0
            } else {
                countdown -= 1
            }
        }
    }

    private func submit() {
        busy = true
        errorText = ""
        Task {
            do {
                let data: LoginData
                if isSmsMode {
                    data = try await AuthService.smsLogin(phone: phone, smsCode: smsCode)
                } else {
                    data = try await AuthService.login(phone: phone, password: password)
                }
                AuthService.persist(data, phone: phone)
                busy = false
            } catch {
                busy = false
                errorText = Self.friendly(error)
            }
        }
    }

    private static func friendly(_ e: Error) -> String {
        let s = e.localizedDescription
        if s.contains("Unable to resolve host") || s.contains("Network is unreachable") {
            return "网络连接失败，请检查网络"
        }
        if s.lowercased().contains("timeout") { return "请求超时，请重试" }
        return s
    }
}
