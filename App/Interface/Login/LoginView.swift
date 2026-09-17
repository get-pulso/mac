import ClerkKit
import SwiftUI

struct LoginView: View {
    // MARK: Internal

    var onboarding = false

    var body: some View {
        Group {
            if onboarding, !stage.isWelcome {
                // Google is done; the profile steps own the centre.
                OnboardingFlowSteps()
            } else if onboarding, session.canContinueFromWelcome, let account = session.welcomeAccount {
                OnboardingContinueButton(
                    account: account,
                    avatar: AnyView(FirstlightAvatar(
                        url: account.avatarURL,
                        name: account.name ?? "Firstlight",
                        size: 24
                    )),
                    action: session.continueFromWelcome
                ).padding(16)
            } else if onboarding, showsWelcomeEntry { welcomeEntry }
            else { form }
        }
        .preference(
            key: OnboardingFormExpandedKey.self,
            value: onboarding && stage.isWelcome && !session.canContinueFromWelcome && !showsWelcomeEntry
        )
    }

    // MARK: Private

    @ObservedObject private var model = LoginViewModel.shared
    @ObservedObject private var session = NativeSession.shared
    @ObservedObject private var stage = OnboardingStage.shared

    private var isWelcomeEntry: Bool { self.model.step == .email || self.model.step == .signup }

    /// The pill stays through sign-in itself: once Google is done and the
    /// profile is being fetched, its label says so. Only a failure to finish
    /// brings the form with Retry and Sign out.
    private var showsWelcomeEntry: Bool {
        self.isWelcomeEntry ||
            (self.model.step == .complete && self.model.error == nil && self.session.error == nil)
    }

    private var signingIn: Bool { self.model.step == .complete }

    /// The page holds one object, and it is armed from the first frame. The
    /// session coming up is not a thing to look at: it is only a reason a press
    /// might have to wait a moment, and the button says that itself, on press.
    private var welcomeEntry: some View {
        // The pill is no wider than its own words now, so the column centres it
        // under the title instead of hanging it off the left edge.
        VStack(spacing: 14) {
            if !session.ready, let error = session.error {
                NativeInlineError(message: error) { Task { await session.start() } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = model.error ?? session.error {
                NativeInlineError(message: error).frame(maxWidth: .infinity, alignment: .leading)
            }
            OnboardingContinueButton(
                isLoading: model.busy || model.awaitingConnection || signingIn || session.isCompletingSignIn,
                isEnabled: canContinue,
                loadingTitle: signingIn ? "Signing in…" :
                    model.awaitingConnection ? "Connecting…" : "Opening Google…",
                action: model.continueWithGoogle
            )
            if session.ready, model.providers.isEmpty {
                Text("Google sign-in is currently unavailable.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .onChange(of: session.ready) { _, ready in if ready { model.connectionReady() } }
        .onChange(of: session.error) { _, error in if error != nil { model.cancelAwaitingConnection() } }
    }

    /// Armed while connecting: the press is held rather than refused. Only a
    /// failed session or a missing provider takes the button away.
    private var canContinue: Bool {
        if self.model.busy || self.model.awaitingConnection { return false }
        if self.session.ready { return !self.model.providers.isEmpty }
        return self.session.error == nil
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !onboarding || (model.step != .email && model.step != .signup) {
                HStack(spacing: 10) {
                    if model.step != .email, model.step != .complete {
                        NativeBackButton(action: model.back).disabled(model.busy)
                    }
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 0)
                }
                if model.step != .complete {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if (!session.ready && session.error == nil) || (model.step == .complete && model.busy) {
                NativeAuthSkeleton()
            } else if !session.ready {
                NativeInlineError(message: session.error ?? "Cannot connect to Firstlight.") {
                    Task { await session.start() }
                }
            } else if model.step == .complete {
                if let error = model.error ?? session.error {
                    NativeInlineError(message: error)
                    HStack {
                        Button("Sign out") { model.run { try await session.signOut() } }
                        Spacer()
                        Button("Retry", action: model.submit).buttonStyle(.borderedProminent).tint(.firstlight)
                    }
                } else { NativeAuthSkeleton() }
            } else {
                if model.step != .email, model.step != .signup {
                    fields.disabled(model.busy)
                    HStack {
                        Spacer()
                        Button(action: model.submit) {
                            NativeAsyncButtonLabel(
                                title: "Continue",
                                loadingTitle: "Verifying…",
                                isLoading: model.busy
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.firstlight)
                        .disabled(model.busy || !model.canSubmit)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                if let error = model.error ?? session.error { NativeInlineError(message: error) }
                secondary
            }
        }
        .font(.system(size: 13)).textFieldStyle(.roundedBorder).controlSize(onboarding ? .large : .regular)
        .multilineTextAlignment(.leading)
        .padding(16).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var fields: some View {
        switch model.step {
        case .email,
             .signup:
            TextField("Email address", text: $model.email).textContentType(.emailAddress)
                .accessibilityLabel("Email address")
        case .password,
             .newPassword:
            SecureField(model.step == .password ? "Password" : "New password", text: $model.password)
                .textContentType(model.step == .password ? .password : .newPassword)
        case .code,
             .mfa:
            TextField(model.backupCode ? "Recovery code" : "Verification code", text: $model.code)
                .textContentType(.oneTimeCode).accessibilityLabel("Verification code")
        case .profile:
            if model.missingFields.contains(.firstName) { TextField("First name", text: $model.firstName) }
            if model.missingFields.contains(.lastName) { TextField("Last name", text: $model.lastName) }
            if model.missingFields.contains(.username) { TextField("Username", text: $model.username) }
            if model.missingFields.contains(.phoneNumber) { TextField("Phone number", text: $model.phone) }
            if model.missingFields
                .contains(.password) { SecureField("Password", text: $model.password).textContentType(.newPassword) }
            if model
                .legalRequired
            {
                Toggle("I accept the terms and privacy policy", isOn: $model.legalAccepted).font(.callout)
            }
        case .complete: EmptyView()
        }
    }

    @ViewBuilder private var secondary: some View {
        switch model.step {
        case .email,
             .signup:
            ForEach(model.providers, id: \.strategy) { provider in
                Button { model.oauth(provider.strategy) } label: {
                    NativeAsyncButtonLabel(
                        title: "Continue with Google",
                        loadingTitle: "Waiting for Google…",
                        isLoading: model.busy
                    ).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(onboarding ? .white : .firstlight)
                .foregroundStyle(onboarding ? Color(red: 0.15, green: 0.17, blue: 0.36) : .white)
                .disabled(model.busy)
                .keyboardShortcut(.defaultAction)
            }
            if model.providers
                .isEmpty { Text("Google sign-in is currently unavailable.").font(.callout).foregroundStyle(.secondary) }
            if model
                .emailEnabled
            {
                Button(model.step == .email ? "Create an account" : "Already have an account? Sign in") {
                    model.error = nil
                    model.step = model.step == .email ? .signup : .email
                }.buttonStyle(.plain).foregroundStyle(.secondary).font(.callout).disabled(model.busy)
            }
        case .password:
            HStack {
                Button("Forgot password?", action: model.recover)
                Spacer()
                if model.canUseEmailCode { Button("Use a code", action: model.sendCode) }
            }.buttonStyle(.plain).font(.callout).disabled(model.busy)
        case .code:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(model.resendAt.timeIntervalSince(context.date)))
                HStack {
                    Button(seconds > 0 ? "Resend in \(seconds)s" : "Resend code", action: model.sendCode)
                        .disabled(seconds > 0 || model.busy)
                    Spacer()
                    if model.canUsePassword { Button("Use password") { model.step = .password } }
                }.buttonStyle(.plain).font(.callout)
            }
        case .mfa: Toggle("Use a recovery code", isOn: $model.backupCode).font(.callout)
        default: EmptyView()
        }
    }

    private var title: String {
        switch self.model.step {
        case .email: "Welcome to Firstlight"
        case .signup: "Create your account"
        case .password: "Enter your password"
        case .code: "Check your email"
        case .profile: "Complete your profile"
        case .mfa: "Verify it's you"
        case .newPassword: "Choose a new password"
        case .complete: "You’re signed in"
        }
    }

    private var subtitle: String {
        switch self.model.step {
        case .code: "Enter the code sent to \(self.model.email)."
        case .mfa: "Enter your authenticator, email or recovery code."
        case .complete: "Opening your friends and activity."
        default: "Your friends and activity, together in your menu bar."
        }
    }
}
