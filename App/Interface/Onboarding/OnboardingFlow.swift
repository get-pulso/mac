import ClerkKit
import Dependencies
import SwiftUI

/// The real path after Google: what the sign-in gave, what is still missing,
/// and the one save that ends in the menu bar. Welcome and the intro stay
/// with `LoginView`; this begins the moment the Firstlight profile is known.
@MainActor
final class OnboardingFlow: ObservableObject {
    // MARK: Internal

    static let shared = OnboardingFlow()

    @Published var name = ""
    @Published var draft = ProfileDraft()
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    /// A rehearsal: the steps run on empty fields and the save is pretend,
    /// so the inputs can be tried without touching the account.
    @Published var rehearsal = false

    var avatarURL: String? { NativeSession.shared.user?.imageUrl }

    /// Sign-in is complete and `userInfo()` succeeded. The steps only exist
    /// for what Google did not give: a first name, then a word about yourself.
    /// Someone whose profile is already filled goes straight to the menu bar.
    /// `about` is what the database holds, or nil when it could not be read:
    /// the steps then start empty, and the save only adds.
    func continueAfterSignIn(about: NativeProfileAbout?) {
        let user = NativeSession.shared.user
        self.error = nil
        self.name = user?.firstName ?? ""
        self.draft = ProfileDraft(
            firstName: self.name, lastName: user?.lastName ?? "", username: user?.username ?? "",
            location: about?.location ?? "", bio: about?.bio ?? "", website: about?.website ?? "",
            twitter: about?.twitter ?? "", telegram: about?.telegram ?? ""
        )
        if self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            OnboardingStage.shared.advance(to: .name)
        } else if self.draft.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            OnboardingStage.shared.advance(to: .about)
        } else {
            self.handoff()
        }
    }

    /// Continue from Welcome during a rehearsal: begin at the name step, empty.
    func startRehearsal() {
        self.error = nil
        self.name = ""
        self.draft = ProfileDraft()
        OnboardingStage.shared.advance(to: .name)
    }

    func continueFromName() {
        guard !self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        OnboardingStage.shared.advance(to: .about)
    }

    func locate() async -> String? { await OnboardingCityLookup.city() }

    /// Clerk for the name, the Firstlight database for the rest. Nothing typed
    /// is lost on failure; the button says Retry.
    func save() {
        guard !self.saving else { return }
        var draft = self.draft
        draft.firstName = self.name
        let normalized = draft.normalized
        guard normalized.errors.isEmpty else {
            self.error = "Check the highlighted fields."
            return
        }
        self.saving = true
        self.error = nil
        Task {
            defer { self.saving = false }
            if self.rehearsal {
                // Long enough to see the label say Saving…; nothing is sent.
                try? await Task.sleep(for: .seconds(0.9))
                self.handoff()
                return
            }
            do {
                guard let user = NativeSession.shared.user else {
                    throw NativeError.message("Sign in again to save your profile.")
                }
                @Dependency(\.network) var network
                let attributes = Clerk.shared.environment?.userSettings.attributes ?? [:]
                if attributes["first_name"]?.enabled == true, normalized.firstName != (user.firstName ?? "") {
                    _ = try await user.update(.init(firstName: normalized.firstName))
                }
                // Onboarding only adds. A field left empty here is not a
                // request to clear one, so nothing written before, or on
                // another Mac, is lost to these steps.
                let about = NativeProfileAbout(
                    bio: normalized.bio.isEmpty ? nil : normalized.bio,
                    location: normalized.location.isEmpty ? nil : normalized.location,
                    website: normalized.website.isEmpty ? nil : normalized.website,
                    twitter: normalized.twitter.isEmpty ? nil : normalized.twitter,
                    telegram: normalized.telegram.isEmpty ? nil : normalized.telegram
                )
                if about != NativeProfileAbout() { _ = try await network.saveProfileAbout(about) }
                try await network.syncNativeProfile()
                _ = try? await user.reload()
                await SocialStore.shared.refresh(force: true)
                self.handoff()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func reset() {
        self.name = ""
        self.draft = ProfileDraft()
        self.saving = false
        self.error = nil
        self.rehearsal = false
    }

    // MARK: Private

    private func handoff() {
        @Dependency(\.windowManager) var window
        window.handoffFromOnboarding()
    }
}

/// The steps after Welcome in the real onboarding window, on `OnboardingFlow`.
struct OnboardingFlowSteps: View {
    // MARK: Internal

    var body: some View {
        ZStack {
            switch self.stage.step {
            case .welcome,
                 .handoff:
                Color.clear
            case .name:
                OnboardingNameStep(
                    name: self.$flow.name, avatarURL: self.flow.avatarURL, namespace: self.travel,
                    onContinue: self.flow.continueFromName
                )
                .transition(OnboardingStage.forward)
            case .about:
                OnboardingAboutStep(
                    draft: self.$flow.draft, name: self.flow.name, avatarURL: self.flow.avatarURL,
                    namespace: self.travel, busy: self.flow.saving, error: self.flow.error,
                    locate: self.flow.locate, onSubmit: self.flow.save
                )
                .transition(OnboardingStage.forward)
            }
        }
        .animation(OnboardingStage.stepAnimation, value: self.stage.step)
    }

    // MARK: Private

    @ObservedObject private var flow = OnboardingFlow.shared
    @ObservedObject private var stage = OnboardingStage.shared
    @Namespace private var travel
}
