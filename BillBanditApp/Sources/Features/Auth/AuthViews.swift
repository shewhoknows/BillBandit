import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

struct LaunchView: View {
    enum Mode {
        case checking
        case welcome
    }

    let mode: Mode
    let onGetStarted: () -> Void

    var body: some View {
        ReceiptBackground {
            VStack(spacing: BBSpacing.xl) {
                Spacer(minLength: BBSpacing.huge)

                MascotView(asset: .welcome, size: 190)

                VStack(spacing: BBSpacing.sm) {
                    Text("BillBandit")
                        .font(BBFont.display(size: 48, weight: .black, relativeTo: .largeTitle))
                        .foregroundStyle(BBColor.textOnBlue)
                        .multilineTextAlignment(.center)

                    Text("Split the trip. Keep the receipt. Settle without the drama.")
                        .font(BBFont.bodyRounded(size: 18, weight: .semibold, relativeTo: .title3))
                        .foregroundStyle(BBColor.textOnBlue.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if mode == .checking {
                    ProgressView("Checking your session")
                        .font(BBFont.bodyRounded(size: 15, weight: .semibold))
                        .tint(BBColor.textOnBlue)
                        .foregroundStyle(BBColor.textOnBlue)
                } else {
                    PrimaryButton(title: "Get started", systemImage: "arrow.right") {
                        onGetStarted()
                    }
                }
            }
            .padding(BBSpacing.xl)
        }
    }
}

@MainActor
@Observable
final class SignInViewModel {
    enum AuthMode: String, CaseIterable, Identifiable {
        case otp = "Email OTP"
        case password = "Password"
        case register = "Register"

        var id: String { rawValue }
    }

    private let authRepository: any AuthRepository
    var mode: AuthMode = .otp
    var email = ""
    var password = ""
    var name = ""
    var otpCode = ""
    var otpChallenge: OTPStartEnvelope?
    var isLoading = false
    var errorMessage: String?

    init(authRepository: any AuthRepository) {
        self.authRepository = authRepository
    }

    func appleSignIn(identityToken: String, nonce: String?, fullName: String?, email: String?) async -> UserProfile? {
        await run {
            try await authRepository.appleSignIn(identityToken: identityToken, nonce: nonce, fullName: fullName, email: email)
        }
    }

    func startOTP() async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter an email address for the OTP."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            otpChallenge = try await authRepository.otpStart(identifier: email)
        } catch {
            errorMessage = error.billBanditMessage
        }
        isLoading = false
    }

    func verifyOTP() async -> UserProfile? {
        guard let otpChallenge else {
            errorMessage = "Start the OTP flow first."
            return nil
        }
        guard otpCode.count == 6 else {
            errorMessage = "Enter the 6-digit code."
            return nil
        }
        return await run {
            try await authRepository.otpVerify(challengeId: otpChallenge.challengeId, code: otpCode)
        }
    }

    func submitPasswordMode() async -> UserProfile? {
        switch mode {
        case .otp:
            return await verifyOTP()
        case .password:
            guard !email.isEmpty, !password.isEmpty else {
                errorMessage = "Enter your email and password."
                return nil
            }
            return await run {
                try await authRepository.emailLogin(email: email, password: password)
            }
        case .register:
            guard name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
                errorMessage = "Enter the name you want on receipts."
                return nil
            }
            guard password.count >= 8 else {
                errorMessage = "Use at least 8 characters for your password."
                return nil
            }
            return await run {
                try await authRepository.register(name: name, email: email, password: password)
            }
        }
    }

    private func run(_ operation: () async throws -> UserProfile) async -> UserProfile? {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            return try await operation()
        } catch {
            errorMessage = error.billBanditMessage
            return nil
        }
    }
}

struct SignInView: View {
    @State var model: SignInViewModel
    let onAuthenticated: (UserProfile) -> Void
    let onUseDevSession: () -> Void
    @State private var currentNonce: String?

    var body: some View {
        @Bindable var model = model

        ReceiptScroll {
            ReceiptCard(eyebrow: "Welcome back", title: "Sign in", subtitle: "Your trips stay tied to this account.") {
                VStack(spacing: BBSpacing.lg) {
                    SignInWithAppleButton(.signIn) { request in
                        let nonce = randomNonceString()
                        currentNonce = nonce
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = sha256(nonce)
                    } onCompletion: { result in
                        handleAppleCompletion(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)

                    Picker("Sign-in method", selection: $model.mode) {
                        ForEach(SignInViewModel.AuthMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: BBSpacing.sm) {
                        if model.mode == .register {
                            HandwrittenTextField(title: "Name", placeholder: "Name on receipts", text: $model.name)
                                .textContentType(.name)
                        }

                        ReceiptTextField(title: "Email", text: $model.email, keyboardType: .emailAddress, textContentType: .emailAddress)

                        if model.mode == .otp {
                            if let otpChallenge = model.otpChallenge {
                                Text("Code sent to \(otpChallenge.maskedIdentifier).")
                                    .font(BBFont.bodyRounded(size: 14, relativeTo: .subheadline))
                                    .foregroundStyle(BBColor.textFaded)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ReceiptTextField(title: "6-digit code", text: $model.otpCode, keyboardType: .numberPad, textContentType: .oneTimeCode)
                            }
                            SecondaryButton(title: model.otpChallenge == nil ? "Send OTP" : "Resend OTP", systemImage: "envelope") {
                                Task { await model.startOTP() }
                            }
                        } else {
                            ReceiptTextField(title: "Password", text: $model.password, textContentType: .password, isSecure: true)
                        }
                    }

                    InlineErrorText(message: model.errorMessage)

                    PrimaryButton(title: primaryTitle, systemImage: "arrow.right", isLoading: model.isLoading) {
                        Task {
                            if let user = await model.submitPasswordMode() {
                                onAuthenticated(user)
                            }
                        }
                    }

                    #if DEBUG
                    SecondaryButton(title: "Use dev session", systemImage: "wrench.and.screwdriver") {
                        onUseDevSession()
                    }
                    #endif
                }
            }
        }
    }

    private var primaryTitle: String {
        switch model.mode {
        case .otp:
            "Verify OTP"
        case .password:
            "Sign in"
        case .register:
            "Create account"
        }
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8)
            else {
                model.errorMessage = "Apple did not return a usable sign-in token."
                return
            }
            let fullName = credential.fullName.map(PersonNameComponentsFormatter().string(from:))
            Task {
                if let user = await model.appleSignIn(
                    identityToken: identityToken,
                    nonce: currentNonce,
                    fullName: fullName,
                    email: credential.email
                ) {
                    onAuthenticated(user)
                }
            }
        case .failure(let error):
            if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled {
                model.errorMessage = nil
            } else {
                model.errorMessage = "Apple sign-in did not finish. Try again or use email."
            }
        }
    }
}

private func randomNonceString(length: Int = 32) -> String {
    precondition(length > 0)
    let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
    var result = ""
    var remainingLength = length

    while remainingLength > 0 {
        var random: UInt8 = 0
        let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
        guard status == errSecSuccess else { fatalError("Unable to generate nonce.") }
        if random < charset.count {
            result.append(charset[Int(random)])
            remainingLength -= 1
        }
    }
    return result
}

private func sha256(_ input: String) -> String {
    let inputData = Data(input.utf8)
    let hashedData = SHA256.hash(data: inputData)
    return hashedData.map { String(format: "%02x", $0) }.joined()
}
