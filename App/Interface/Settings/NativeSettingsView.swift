import ClerkKit
import Combine
import Dependencies
import SwiftUI

/// The titlebar, navigation and sidebar are owned by AppKit. Content uses the
/// system grouped form, with no imitation toolbar or titlebar-safe-area padding.
struct NativeSettingsView: View {
    // MARK: Internal

    @ObservedObject var model: NativeSettingsModel

    var body: some View {
        settingsRoot
            .alert(confirmTitle, isPresented: $confirming) {
                Button("Cancel", role: .cancel) { confirmAction = nil }
                Button("Confirm", role: .destructive) { confirmAction?(); confirmAction = nil }
            }
    }

    // MARK: Private

    private enum CopyAction: Hashable {
        case authenticatorKey
        case friendCode
        case recoveryCodes
    }

    @ObservedObject private var session = NativeSession.shared
    @ObservedObject private var socialStore = SocialStore.shared
    @AppStorage("firstlight.appearance") private var appearance = "system"
    @AppStorage("firstlight.trackingPaused") private var trackingPaused = false
    @State private var confirming = false
    @State private var confirmTitle = ""
    @State private var confirmAction: (() -> Void)?
    @State private var launchAtLoginEnabled = false
    @State private var launchAtLoginError: String?
    @State private var launchAtLoginStatus = LaunchAtLogin.status

    @State private var copiedAction: CopyAction?

    private var settingsRoot: some View {
        settingsContent
            .formStyle(.grouped)
            .font(.system(size: 13))
            .controlSize(.regular)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await model.load() }
            .onAppear { refreshLaunchAtLogin() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshLaunchAtLogin()
            }
            .task(id: copiedAction) {
                guard copiedAction != nil else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                copiedAction = nil
            }
            .onChange(of: appearance) { _, value in
                NSApp.appearance = value == "system" ? nil : NSAppearance(named: value == "dark" ? .darkAqua : .aqua)
            }
    }

    @ViewBuilder private var settingsContent: some View {
        Group {
            if model.route.section == .groups {
                NativeGroupsSettingsView(model: model.groupSettings, navigate: model.navigateGroups)
            } else if model.route.page == "edit" {
                NativeProfileEditor(model: model)
            } else {
                Form {
                    if model.route.page.isEmpty { sectionContent } else { pageContent }
                    if let error = model.error { NativeInlineError(message: error) }
                    if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var name: String { self.session.user?.firstName ?? self.session.user?.username ?? "Your account" }

    private var activityPeriod: Binding<String> {
        Binding(get: { socialStore.period }, set: self.socialStore.setPeriod)
    }

    @ViewBuilder private var sectionContent: some View {
        switch model.route.section {
        case .account:
            HStack(spacing: 12) {
                FirstlightAvatar(url: session.user?.imageUrl, name: name, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    let fullName = [session.user?.firstName, session.user?.lastName].compactMap { $0 }
                        .joined(separator: " ")
                    Text(fullName.isEmpty ? name : fullName).font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let username = session.user?.username, !username.isEmpty {
                        Text("@\(username)").foregroundStyle(.secondary)
                    }
                    let location = model.metadata("location")
                    if !location.isEmpty { NativeLocationLabel(text: location, size: 13) }
                }
                Spacer(minLength: 8)
                Button("Edit profile") { model.navigate(.account, page: "edit") }
                    .nativeSettingsActionButton()
            }.padding(.vertical, 6)
            if ["website", "twitter", "telegram"].contains(where: { !model.metadata($0).isEmpty }) {
                panel {
                    profileLink("Website", raw: model.metadata("website"))
                    profileLink("X", raw: model.metadata("twitter"), host: "x.com")
                    profileLink("Telegram", raw: model.metadata("telegram"), host: "t.me")
                }
            }
            panel {
                info("Email", value: session.user?.primaryEmailAddress?.emailAddress ?? "")
                LabeledContent("Friend code") {
                    HStack(spacing: 8) {
                        if model.inviteCode.isEmpty, model.inviteError == nil {
                            NativeDelayedSkeleton { NativeSkeletonShape(width: 76, height: 12) }
                        } else {
                            Text(model.inviteCode.isEmpty ? "Unavailable" : model.inviteCode)
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Button { copy(model.inviteCode, action: .friendCode) } label: {
                            NativeCopyButtonLabel(title: "Copy", copied: copiedAction == .friendCode)
                        }
                        .nativeSettingsActionButton()
                        .disabled(model.inviteCode.isEmpty)
                    }
                }
            }
            if let error = model.inviteError { NativeInlineError(message: error) { Task { await model.load() } } }
            Button {
                confirm("Sign out of Firstlight on this Mac?") {
                    model.run("Signing out…", key: "sign-out") { try await NativeSession.shared.signOut() }
                }
            } label: {
                NativeAsyncButtonLabel(
                    title: "Sign out…",
                    loadingTitle: "Signing out…",
                    isLoading: model.isRunning("sign-out")
                )
            }
            .nativeSettingsActionButton()
            .disabled(model.busy)
        case .general:
            panel {
                Toggle("Open Firstlight at login", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                if launchAtLoginStatus == .requiresApproval {
                    Text("Firstlight is disabled in Login Items. Allow it in System Settings to start automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items…") { LaunchAtLogin.openSystemSettings() }
                        .nativeSettingsActionButton()
                } else if let launchAtLoginError {
                    NativeInlineError(message: launchAtLoginError)
                }
            }
            panel {
                Picker("Activity period", selection: activityPeriod) {
                    Text("24 hours").tag("24h")
                    Text("7 days").tag("7d")
                    Text("30 days").tag("30d")
                }
                Toggle("Pause activity tracking", isOn: $trackingPaused)
                    .toggleStyle(.switch).controlSize(.small)
                Text(
                    "Firstlight records active time and the foreground app, never window titles or content. Tracking pauses while your Mac is idle or locked."
                )
                .font(.callout).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    confirm("Permanently delete all activity history for your account?") { model.resetActivity() }
                } label: {
                    NativeAsyncButtonLabel(
                        title: "Clear activity history…",
                        loadingTitle: "Clearing…",
                        isLoading: model.isRunning("clear-activity")
                    )
                }
                .nativeSettingsActionButton()
                .disabled(model.busy)
            }
            Button("Quit Firstlight") { NSApp.terminate(nil) }
                .nativeSettingsActionButton()
        case .security:
            panel {
                info("Sign-in method", value: "Google")
                if let google = session.user?.externalAccounts.first(where: {
                    $0.provider == "google" || $0.provider == "oauth_google"
                }), !google.emailAddress.isEmpty {
                    info("Google account", value: google.emailAddress)
                }
                if model.attributeEnabled("email_address") {
                    actionRow(
                        "Email address",
                        value: session.user?.primaryEmailAddress?.emailAddress ?? "",
                        action: "Change"
                    ) { model.navigate(.security, page: "email") }
                }
                if model.attributeEnabled("password") && session.user?.passwordEnabled == true {
                    actionRow(
                        "Password",
                        value: session.user?.passwordEnabled == true ? "Enabled" : "Not set",
                        action: "Change"
                    ) { model.navigate(.security, page: "password") }
                }
                if model.attributeEnabled("authenticator_app") || session.user?.totpEnabled == true {
                    actionRow(
                        "Authenticator app",
                        value: session.user?.totpEnabled == true ? "Enabled" : "Not set",
                        action: session.user?.totpEnabled == true ? "Remove…" : "Set up",
                        loadingTitle: session.user?.totpEnabled == true ? "Removing…" : "Starting…",
                        key: session.user?.totpEnabled == true ? "disable-totp" : "setup-totp"
                    ) {
                        if session.user?
                            .totpEnabled == true { confirm("Remove your authenticator app?") { model.disableTOTP() } }
                        else { model.setupTOTP() }
                    }
                }
                if session.user?
                    .backupCodeEnabled ==
                    true
                {
                    Button {
                        confirm("Replace your existing recovery codes?") { model.regenerateBackupCodes() }
                    } label: {
                        NativeAsyncButtonLabel(
                            title: "Generate new recovery codes…",
                            loadingTitle: "Generating…",
                            isLoading: model.isRunning("backup-codes")
                        )
                    }
                    .nativeSettingsActionButton()
                    .disabled(model.busy)
                }
            }
            panel {
                Button("Active sessions") { model.navigate(.sessions) }
                    .nativeSettingsActionButton()
            }
            if session.user?
                .deleteSelfEnabled ==
                true
            {
                Button("Delete account…", role: .destructive) { model.navigate(.security, page: "delete") }
                    .nativeSettingsActionButton()
            }
        case .sessions:
            panel(loading: model.sessionsLoading && model.sessionsLoaded) {
                if model.sessionsLoading, !model.sessionsLoaded {
                    NativeLabeledRowsSkeleton(rows: 2)
                } else {
                    ForEach(model.sessions, id: \.id) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(
                                    item.id == session.session?.id ? "This Mac" : item.latestActivity?
                                        .browserName ?? item
                                        .latestActivity?.deviceType ?? "Device"
                                )
                                Text(item.lastActiveAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.id == session.session?
                                .id { Text("Current").font(.caption).foregroundStyle(.secondary) }
                            else if item.status == .active {
                                Button {
                                    confirm("Sign out this device?") { model.revoke(item) }
                                } label: {
                                    NativeAsyncButtonLabel(
                                        title: "Sign out…",
                                        loadingTitle: "Signing out…",
                                        isLoading: model.isRunning("revoke-session-\(item.id)")
                                    )
                                }
                                .nativeSettingsActionButton()
                                .disabled(model.busy)
                            } else { Text(item.status.rawValue).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 2)
                    }
                }
                if let error = model.sessionsError {
                    NativeInlineError(message: error) { model.refreshSessions(force: true) }
                } else if model.sessions.isEmpty,
                          model.sessionsLoaded { Text("No other signed-in devices.").foregroundStyle(.secondary) }
            }
        case .groups:
            EmptyView() // Groups owns its form and navigation within this same detail pane.
        case .about:
            panel {
                info("Version", value: version)
                info("API", value: AppEnvironment.baseURL.absoluteString)
                Text("Friends and activity in your menu bar.").foregroundStyle(.secondary)
                Button("Check for updates") { @Dependency(\.updater) var updater; updater.checkForUpdates() }
                    .nativeSettingsActionButton()
                    .disabled(AppEnvironment.isLocalBackend)
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch model.route.page {
        case "email":
            labeled("New email address", text: $model.email)
            primary("Continue", loadingTitle: "Continuing…", key: "change-email", action: model.changeEmail)
        case "verify-email":
            labeled("Verification code", text: $model.code)
            primary(
                "Verify and use this email",
                loadingTitle: "Verifying…",
                key: "verify-email",
                action: model.verifyEmail
            )
        case "password":
            if session.user?
                .passwordEnabled ==
                true { SecureField("Current password", text: $model.currentPassword).textContentType(.password) }
            SecureField("New password", text: $model.password).textContentType(.newPassword)
            primary("Update password", loadingTitle: "Updating…", key: "change-password", action: model.changePassword)
        case "totp":
            Text("Add this setup key to your authenticator, then enter its six-digit code.").foregroundStyle(.secondary)
            if let secret = model.totp?
                .secret
            {
                Text(secret).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button { copy(secret, action: .authenticatorKey) } label: {
                    NativeCopyButtonLabel(title: "Copy key", copied: copiedAction == .authenticatorKey)
                }
                .nativeSettingsActionButton()
            }
            labeled("Authentication code", text: $model.code)
            primary(
                "Enable two-factor authentication",
                loadingTitle: "Enabling…",
                key: "verify-totp",
                action: model.verifyTOTP
            )
        case "backup-codes":
            Text("Keep these somewhere safe. Each code can only be used once.").foregroundStyle(.secondary)
            Text(model.backupCodes.joined(separator: "\n")).font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Button { copy(model.backupCodes.joined(separator: "\n"), action: .recoveryCodes) } label: {
                NativeCopyButtonLabel(title: "Copy codes", copied: copiedAction == .recoveryCodes)
            }
            .nativeSettingsActionButton()
            primary("I've saved my codes") { model.backupCodes = []; model.navigate(.security) }
        case "verify-identity":
            Text(
                model
                    .verificationMethod == "email" ? "Enter the code sent to your email." :
                    "Confirm your identity to make this change."
            ).foregroundStyle(.secondary)
            if model.verificationMethod == "password" { SecureField("Password", text: $model.password) }
            else {
                labeled(
                    model.verificationMethod == "backup" ? "Recovery code" : "Verification code",
                    text: $model.code
                )
            }
            primary("Verify", loadingTitle: "Verifying…", key: "verify-identity", action: model.verifyIdentity)
        case "delete":
            Text(
                "This permanently removes your Firstlight account, activity and friendships. Shared groups remain, without your membership or ownership. This cannot be undone."
            )
            .foregroundStyle(.secondary)
            labeled("Type DELETE to confirm", text: $model.confirmation)
            Button(role: .destructive, action: model.deleteAccount) {
                NativeAsyncButtonLabel(
                    title: "Delete my account",
                    loadingTitle: "Deleting…",
                    isLoading: model.isRunning("delete-account")
                )
            }
            .nativeSettingsActionButton()
            .disabled(model.confirmation != "DELETE" || model.busy)
        default: EmptyView()
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development"
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { setLaunchAtLogin($0) }
        )
    }

    /// Sections carry no titles: the sidebar selection already names the screen,
    /// and rows are self-describing. A header appears only to host the refresh spinner.
    @ViewBuilder private func panel(
        loading: Bool = false,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if loading {
            Section {
                content()
            } header: {
                HStack {
                    Spacer()
                    NativeProgress(active: true, label: "Refreshing")
                }
            }
        } else {
            Section { content() }
        }
    }

    private func info(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value.isEmpty ? "Not set" : value).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    @ViewBuilder private func profileLink(_ title: String, raw: String, host: String? = nil) -> some View {
        if !raw.isEmpty {
            let url = host.flatMap { host in
                ProfileDraft.socialHandle(
                    raw,
                    hosts: host == "x.com" ? ["x.com", "twitter.com"] : ["t.me", "telegram.me"]
                )
                .flatMap { URL(string: "https://\(host)/\($0)") }
            } ?? (host == nil ? ProfileDraft.websiteURL(raw) : nil)
            LabeledContent(title) {
                if let url {
                    Link(host == nil ? url.host ?? raw : "@\(url.lastPathComponent)", destination: url).lineLimit(1)
                } else { Text(raw).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }

    private func actionRow(
        _ title: String,
        value: String,
        action: String,
        loadingTitle: String? = nil,
        key: String? = nil,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if !value.isEmpty { Text(value).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Button(action: perform) {
                NativeAsyncButtonLabel(
                    title: action,
                    loadingTitle: loadingTitle ?? action,
                    isLoading: key.map(model.isRunning) ?? false
                )
            }
            .nativeSettingsActionButton()
            .disabled(model.busy)
        }
    }

    private func labeled(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text).labelsHidden().disabled(model.busy)
                .frame(minWidth: 160, maxWidth: 270)
        }
    }

    private func primary(
        _ title: String,
        loadingTitle: String? = nil,
        key: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                NativeAsyncButtonLabel(
                    title: title,
                    loadingTitle: loadingTitle ?? title,
                    isLoading: key.map(model.isRunning) ?? false
                )
            }
            .nativeSettingsPrimaryButton()
            .disabled(model.busy).keyboardShortcut(.defaultAction)
        }
    }

    private func copy(_ text: String, action: CopyAction) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return }
        self.copiedAction = action
    }

    private func refreshLaunchAtLogin() {
        self.launchAtLoginStatus = LaunchAtLogin.status
        self.launchAtLoginEnabled = self.launchAtLoginStatus == .enabled
        if self.launchAtLoginStatus == .enabled { self.launchAtLoginError = nil }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        self.launchAtLoginError = nil
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            self.launchAtLoginError = error.localizedDescription
        }
        self.refreshLaunchAtLogin()
    }

    private func confirm(_ title: String, action: @escaping () -> Void) {
        guard !self.model.busy else { return }
        self.confirmTitle = title; self.confirmAction = action; self.confirming = true
    }
}

struct NativeSettingsSidebar: View {
    // MARK: Internal

    @ObservedObject var model: NativeSettingsModel

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $model.search) {
                if let first = sections.first { model.navigate(first) }
            }
            .frame(height: 22)
            .padding(.horizontal, 10).padding(.top, 10)
            .onChange(of: sections) { _, sections in
                // Typing narrows the sidebar; keep the detail pane on a visible section.
                guard let first = sections.first, !sections.contains(model.route.section) else { return }
                model.navigate(first, keepingSearch: true)
            }
            if sections.contains(.account) {
                Button { model.navigate(.account) } label: {
                    HStack(spacing: 8) {
                        FirstlightAvatar(
                            url: session.user?.imageUrl,
                            name: session.user?.firstName ?? "Account",
                            size: 28
                        )
                        .overlay { NativeSettingsAvatarBorder() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.user?.firstName ?? "Your account").lineLimit(1)
                            Text("Account").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        model.route.section == .account ?
                            Color(NSColor.unemphasizedSelectedContentBackgroundColor) : .clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.route.section == .account ? [.isSelected] : [])
                .padding(.horizontal, 10).padding(.vertical, 12)
            }
            NeutralSettingsList(
                items: sections.filter { $0 != .account }.map { .init(title: $0.rawValue, icon: $0.icon) },
                selection: Binding(
                    get: { model.route.section.rawValue },
                    set: { value in
                        if let value,
                           let section = NativeSettingsModel.Section(rawValue: value) { model.navigate(section) }
                    }
                )
            )
            .overlay {
                if sections.isEmpty {
                    Text("No results").font(.callout).foregroundStyle(.secondary)
                }
            }
        }.font(.system(size: 13))
    }

    // MARK: Private

    @ObservedObject private var session = NativeSession.shared

    private var sections: [NativeSettingsModel.Section] {
        NativeSettingsModel.Section.allCases.filter { model.search.isEmpty || $0.matches(model.search) }
    }
}
