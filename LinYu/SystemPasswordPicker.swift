import AuthenticationServices
import SwiftUI

@MainActor
final class SystemPasswordPicker: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var completion: ((String, String) -> Void)?
    private var failure: ((String) -> Void)?
    private var controller: ASAuthorizationController?
    private var window: UIWindow?
    func choose(onFailure: @escaping (String) -> Void, completion: @escaping (String, String) -> Void) {
        guard controller == nil,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        self.window = window
        self.completion = completion
        self.failure = onFailure
        let controller = ASAuthorizationController(authorizationRequests: [ASAuthorizationPasswordProvider().createRequest()])
        self.controller = controller
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window! }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASPasswordCredential { completion?(credential.user, credential.password) }
        finish()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code != .canceled {
            failure?("未找到可用的已保存密码")
            AppLog.shared.w("系统密码请求未返回凭证：\((error as NSError).domain) / \((error as NSError).code)")
        }
        finish()
    }
    private func finish() { controller = nil; window = nil; completion = nil; failure = nil }
}
