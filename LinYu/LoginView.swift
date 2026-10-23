import SwiftUI

/// 登录页 —— 逐条对照 Android 的 `LoginScreen.kt`。
///
/// ## 布局和配色是**写死的**，不跟深浅模式走
///
/// Android 那张登录卡片是固定白底（`Color.White`），输入框配色也写死
/// （见 Android `loginFieldColors()` 的注释：用主题色的话，深色模式下
/// `onSurface` 是浅色，浅色字压在白卡片上就灰蒙蒙一片）。
/// iOS 这边同样：不管系统深浅，登录页永远是蓝渐变 + 白卡片。
struct LoginView: View {
    @EnvironmentObject private var session: Session

    @State private var phone = ""
    @State private var password = ""
    @State private var smsCode = ""
    @State private var isSmsMode = true
    @State private var busy = false
    @State private var errorText: String?
    @State private var countdown = 0
    @StateObject private var systemPasswords = SystemPasswordPicker()

    private var canSubmit: Bool {
        if phone.count != 11 { return false }
        return isSmsMode ? smsCode.count >= 4 : !password.isEmpty
    }

    var body: some View {
        ZStack {
            // 背景渐变（三个色标与 Android 完全一致）
            LinearGradient(
                colors: [
                    Color(hex: 0x1A73E8),
                    Color(hex: 0x0D47A1),
                    Color(hex: 0x051D40)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 装饰圆 ①：左上，280pt，白色 4%
            Circle()
                .fill(Color.white.opacity(0.04))
                .frame(width: 280, height: 280)
                .offset(x: -120, y: -80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // 装饰圆 ②：右下，180pt，白色 6%
            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 180, height: 180)
                .offset(x: 60, y: 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            ScrollView {
                VStack(spacing: 0) {
                    logo
                    card
                }
                .padding(.horizontal, 28)
                .padding(.top, 90)
                .padding(.bottom, 28)
                .offset(y: -50)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        // 固定白色登录卡片在系统深色模式下也使用深色占位文字。
        .environment(\.colorScheme, .light)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onAppear {
            // 回填上次保存的凭据：手机号总是填；密码只有上次是**密码登录**才有。
            // 验证码是一次性的，不存。
            if phone.isEmpty, let saved = SavedCredential.phone { phone = saved }
            if password.isEmpty, let saved = SavedCredential.password { password = saved }
            if !password.isEmpty { isSmsMode = false }
        }
    }

    // MARK: - Logo

    private var logo: some View {
        VStack(spacing: 0) {
            // 直接使用 Android 的 app_logo 图片资源。
            Image("LoginLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text("淋 浴")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 16)

            Text("Hualala · 校园热水")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))

            Spacer()
                .frame(height: 20)
        }
    }

    // MARK: - 登录卡片

    private var card: some View {
        VStack(spacing: 0) {
            Text("欢迎回来")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Color(hex: 0x1A1A1A))

            Text("请使用校园账号登录")
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .padding(.top, 4)
                .padding(.bottom, 20)

            // 密码 / 验证码切换
            Button {
                isSmsMode.toggle()
                errorText = nil
            } label: {
                Text(isSmsMode ? "密码登录" : "验证码登录")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: 0x1A73E8))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(InstantButtonStyle())
            .disabled(busy)
            .padding(.bottom, 16)

            // 当前模式的一句说明。放这儿是因为用户最容易卡住的两个点都在这：
            // 没注册的人不知道能不能直接用（能，会自动注册），
            // 没设过密码的人不知道密码该填什么（填不了，用验证码）
            Text(isSmsMode ? "未注册的手机号将自动创建账号" : "未设置密码？请使用手机号验证码登录")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .padding(.bottom, 12)

            phoneField
                .padding(.bottom, 14)

            if isSmsMode { smsField } else { passwordField }

            if !isSmsMode {
                Button("使用已保存的密码") {
                    systemPasswords.choose(onFailure: { errorText = $0 }) { user, secret in
                        phone = user
                        password = secret
                    }
                }
                .font(.system(size: 13)).padding(.top, 12)
                .buttonStyle(InstantButtonStyle()).disabled(busy)
            }

            loginButton
                .padding(.top, 24)

            if let msg = errorText {
                Text(msg)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: 0xC62828))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: 0xFFFFEBEE))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 16)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        // 卡片是白底浮在渐变上，这里**必须**给阴影 —— Android 是 shadowElevation 12
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    // MARK: - 输入框

    private var phoneField: some View {
        outlinedField(
            title: "手机号",
            text: $phone,
            systemImage: "phone.fill",
            keyboard: isSmsMode ? .numberPad : .default,
            secured: false
        )
    }

    private var passwordField: some View {
        outlinedField(
            title: "密码",
            text: $password,
            systemImage: "lock.fill",
            keyboard: .default,
            secured: true
        )
    }

    private var smsField: some View {
        HStack(alignment: .top, spacing: 12) {
            outlinedField(
                title: "验证码",
                text: $smsCode,
                systemImage: nil,
                keyboard: .numberPad,
                secured: false
            )
            Button {
                sendCode()
            } label: {
                // 固定宽度 84pt：文案在「发送」↔「60s」之间变化时按钮宽度不变，
                // 否则会把左边自适应的输入框挤窄/挤宽，看着像抖了一下
                Text(countdown > 0 ? "\(countdown)s" : "发送")
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(width: 84, height: 56)
                    .background(canSend ? Color(hex: 0x1A73E8) : Color(hex: 0x90CAF9))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(InstantButtonStyle())
            .disabled(!canSend)
        }
    }

    private var canSend: Bool { !busy && countdown == 0 && phone.count == 11 }

    /// 统一的外框输入框：圆角 14、蓝色图标、右侧清空按钮
    /// （对照 Android 的 OutlinedTextField + loginFieldColors）
    private func outlinedField(
        title: String,
        text: Binding<String>,
        systemImage: String?,
        keyboard: UIKeyboardType,
        secured: Bool
    ) -> some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: 0x1A73E8))
                    .frame(width: 20)
            }

            Group {
                if secured {
                    SecureField(title, text: text)
                } else {
                    TextField(title, text: text)
                }
            }
            .font(.system(size: 15))
            .foregroundColor(Color(hex: 0x1A1A1A))
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            // 告诉系统这个框是什么，iOS 的密码自动填充才能识别并回填
            .textContentType(secured ? .password : (title == "手机号" ? .username : .oneTimeCode))

            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.gray)
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel("清空\(title)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(hex: 0x1A73E8).opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - 登录按钮

    private var loginButton: some View {
        Button {
            submit()
        } label: {
            ZStack {
                if busy {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.9)
                } else {
                    Text("登 录")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(canSubmit ? Color(hex: 0x1A73E8) : Color(hex: 0x90CAF9))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(InstantButtonStyle())
        .disabled(busy || !canSubmit)
    }

    // MARK: - 动作

    private func sendCode() {
        guard phone.count == 11 else { return }
        countdown = 60
        startCountdown()
        Task {
            do {
                try await AuthService.sendSmsCode(phone: phone)
            } catch {
                errorText = Self.friendly(error)
            }
        }
    }

    private func startCountdown() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if countdown <= 0 {
                timer.invalidate()
            } else {
                countdown -= 1
            }
        }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                let data = isSmsMode
                    ? try await AuthService.smsLogin(phone: phone, smsCode: smsCode)
                    : try await AuthService.login(phone: phone, password: password)
                // 验证码是一次性的，只有密码登录才存——下次打开自动填好，一键登录
                if !isSmsMode { SavedCredential.save(phone: phone, password: password) }
                AuthService.persist(data, phone: phone)
            } catch {
                errorText = Self.friendly(error)
            }
        }
    }

    private static func friendly(_ e: Error) -> String {
        let s = e.localizedDescription
        if s.contains("登录") || s.contains("密码") || s.contains("验证码") { return s }
        return "登录失败：\(s)"
    }
}
