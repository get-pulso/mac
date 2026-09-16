import AuthenticationServices
import ClerkKit
import SwiftUI

@MainActor
final class LoginViewModel: ObservableObject {
    // MARK: Internal

    enum Step { case email, password, code, signup, profile, mfa, newPassword, complete }

    static let shared = LoginViewModel()

    @Published var step: Step = .email
    @Published var email = ""
    @Published var password = ""
    @Published var code = ""
    @Published var firstName = ""
    @Published var lastName = ""
    @Published var username = ""
    @Published var phone = ""
    @Published var legalAccepted = false
    @Published var busy = false
    @Published var error: String?
    @Published var resendAt = Date.distantPast
    @Published var backupCode = false

    var providers: [Clerk.Environment.UserSettings.SocialConfig] {
        guard NativeSession.shared.ready else { return [] }
        return (Clerk.shared.environment?.userSettings.social.values.map { $0 } ?? [])
            .filter { $0.enabled && $0.authenticatable && $0.strategy == "oauth_google" }
    }

    var emailEnabled: Bool {
        // Google is the only sign-in entry point. Code/password forms are kept
        // for required continuation and account verification, not alternative login.
        false
    }

    var missingFields: [SignUp.Field] { self.signUp?.missingFields ?? [] }
    var canUseEmailCode: Bool { self.signIn?.supportedFirstFactors?.contains { $0.strategy == .emailCode } == true }
    var canUsePassword: Bool { self.signIn?.supportedFirstFactors?.contains { $0.strategy == .password } == true }
    var legalRequired: Bool { Clerk.shared.environment?.userSettings.signUp.legalConsentEnabled == true }
    var canSubmit: Bool {
        switch self.step {
        case .code,
             .mfa: !self.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .password,
             .newPassword: !self.password.isEmpty
        case .profile:
            (!self.missingFields.contains(.firstName) || !self.firstName.isEmpty) &&
                (!self.missingFields.contains(.lastName) || !self.lastName.isEmpty) &&
                (!self.missingFields.contains(.username) || !self.username.isEmpty) &&
                (!self.missingFields.contains(.phoneNumber) || !self.phone.isEmpty) &&
                (!self.missingFields.contains(.password) || !self.password.isEmpty) &&
                (!self.legalRequired || self.legalAccepted)
        default: true
        }
    }

    func run(_ action: @escaping () async throws -> Void) {
        guard !self.busy else { return }
        self.busy = true
        self.error = nil
        Task {
            defer { busy = false }
            do { try await action() } catch {
                let failure = error as NSError
                if failure.domain == ASWebAuthenticationSessionError.errorDomain,
                   failure.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                {
                    self.error = nil
                } else { self.error = error.localizedDescription }
            }
        }
    }

    func submit() {
        self.run {
            switch self.step {
            case .email:
                self.signUp = nil
                self.reset = false
                let attempt = try await Clerk.shared.auth
                    .signIn(self.email.trimmingCharacters(in: .whitespacesAndNewlines))
                try await self.advance(attempt)
            case .password:
                guard let signIn = self.signIn else { return }
                let result = try await signIn.authenticateWithPassword(self.password)
                try await self.advance(result)
            case .code:
                let code = self.code.trimmingCharacters(in: .whitespacesAndNewlines)
                if let signUp = self.signUp {
                    let result = try await signUp.verifyEmailCode(code)
                    try await self.advance(result)
                } else if let signIn = self.signIn {
                    let result = try await signIn.verifyCode(code)
                    try await self.advance(result)
                }
            case .signup:
                self.signIn = nil
                let result = try await Clerk.shared.auth
                    .signUp(emailAddress: self.email.trimmingCharacters(in: .whitespacesAndNewlines))
                try await self.advance(result)
            case .profile:
                guard let signUp = self.signUp else { return }
                let result = try await signUp.update(
                    password: self.missingFields.contains(.password) ? self.password : nil,
                    firstName: self.missingFields.contains(.firstName) ? self.firstName : nil,
                    lastName: self.missingFields.contains(.lastName) ? self.lastName : nil,
                    username: self.missingFields.contains(.username) ? self.username : nil,
                    phoneNumber: self.missingFields.contains(.phoneNumber) ? self.phone : nil,
                    legalAccepted: self.legalRequired ? self.legalAccepted : nil
                )
                try await self.advance(result)
            case .mfa:
                guard let signIn = self.signIn else { return }
                let result = try await signIn.verifyMfaCode(
                    self.code.trimmingCharacters(in: .whitespacesAndNewlines),
                    type: self.backupCode ? .backupCode : self.mfaType
                )
                try await self.advance(result)
            case .newPassword:
                guard let signIn = self.signIn else { return }
                let result = try await signIn.resetPassword(newPassword: self.password, signOutOfOtherSessions: true)
                try await self.advance(result)
            case .complete:
                try await NativeSession.shared.finishSignIn()
            }
        }
    }

    func oauth(_ provider: String) {
        self.run {
            let result = try await Clerk.shared.auth.signInWithOAuth(provider: OAuthProvider(strategy: provider))
            switch result {
            case let .signIn(value): try await self.advance(value)
            case let .signUp(value): try await self.advance(value)
            }
        }
    }

    func sendCode() {
        self.run {
            guard Date() >= self.resendAt else { return }
            if let signUp = self.signUp { self.signUp = try await signUp.sendEmailCode() }
            else if let signIn = self.signIn {
                if self.reset { self.signIn = try await signIn.sendResetPasswordEmailCode() }
                else { self.signIn = try await signIn.sendEmailCode() }
            }
            self.code = ""
            self.step = .code
            self.resendAt = Date().addingTimeInterval(30)
        }
    }

    func recover() {
        self.run {
            guard let signIn = self.signIn else { return }
            self.signIn = try await signIn.sendResetPasswordEmailCode()
            self.reset = true
            self.code = ""
            self.step = .code
            self.resendAt = Date().addingTimeInterval(30)
        }
    }

    func back() {
        guard !self.busy else { return }
        self.step = .email
        self.error = nil
        self.password = ""
        self.code = ""
        self.signIn = nil
        self.signUp = nil
        self.reset = false
    }

    // MARK: Private

    private var signIn: SignIn?
    private var signUp: SignUp?
    private var mfaType: SignIn.MfaType = .totp
    private var reset = false

    private func advance(_ value: SignIn) async throws {
        self.signIn = value
        self.code = ""
        switch value.status {
        case .complete:
            self.password = ""
            self.step = .complete
            try await NativeSession.shared.finishSignIn()
        case .needsFirstFactor:
            if self.canUseEmailCode {
                self.signIn = try await value.sendEmailCode()
                self.resendAt = Date().addingTimeInterval(30)
                self.step = .code
            } else if self.canUsePassword { self.step = .password }
            else { throw NativeError.message("Use a connected sign-in provider for this account.") }
        case .needsSecondFactor,
             .needsClientTrust:
            self.backupCode = false
            if value.supportedSecondFactors?.contains(where: { $0.strategy == .totp }) == true {
                self.mfaType = .totp
            } else if value.supportedSecondFactors?.contains(where: { $0.strategy == .emailCode }) == true {
                self.signIn = try await value.sendMfaEmailCode()
                self.mfaType = .emailCode
            } else if value.supportedSecondFactors?.contains(where: { $0.strategy == .phoneCode }) == true {
                self.signIn = try await value.sendMfaPhoneCode()
                self.mfaType = .phoneCode
            } else { self.backupCode = true }
            self.step = .mfa
        case .needsNewPassword: self.password = ""; self.step = .newPassword
        default: throw NativeError.message("Please start sign-in again.")
        }
    }

    private func advance(_ value: SignUp) async throws {
        self.signUp = value
        if value.status == .complete {
            self.password = ""
            self.step = .complete
            try await NativeSession.shared.finishSignIn()
        } else if !value.missingFields.isEmpty { self.step = .profile }
        else if value.unverifiedFields.contains(.emailAddress) {
            self.signUp = try await value.sendEmailCode()
            self.resendAt = Date().addingTimeInterval(30)
            self.code = ""
            self.step = .code
        } else {
            throw NativeError
                .message(
                    "This account requires additional verification: \(value.unverifiedFields.map(\.rawValue).joined(separator: ", "))."
                )
        }
    }
}
