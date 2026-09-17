import ClerkKit
import Dependencies
import SwiftUI

/// How much of the day friends see, as the one question the onboarding asks.
/// Settings keeps the two channels apart; here they move together, because a
/// person on their first day is choosing a posture, not tuning a channel.
enum OnboardingSharePreset: String, CaseIterable, Identifiable {
    case everything, totals, time

    // MARK: Internal

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .everything: "Everything"
        case .totals: "Totals only"
        case .time: "Just my time"
        }
    }

    var detail: String {
        switch self {
        case .everything: "Friends see the app you're in, your agents' tools and shifts."
        case .totals: "Friends see hours and counts, never app or tool names."
        case .time: "Apps and agents stay hidden. Your time today still shows."
        }
    }

    var level: NativeShareLevel {
        switch self {
        case .everything: .detail
        case .totals: .total
        case .time: .off
        }
    }

    var settings: NativeSharingSettings { .init(apps: self.level, agents: self.level) }
}

/// Everything the chapters do that leaves the window: the saves, the link,
/// the friend request, the city, the photo. The real path talks to Clerk and
/// the API; a rehearsal and the fixture preview answer from memory, so the
/// same views can be tried without touching an account.
struct OnboardingBackend {
    enum CodeOutcome: Equatable {
        /// Friends at once: the code was an invitation to exactly that.
        case connected(String)
        /// A request, waiting on the other person.
        case requested(String)
    }

    var saveProfile: @MainActor (_ draft: ProfileDraft) async throws -> Void
    var saveSharing: @MainActor (_ preset: OnboardingSharePreset) async throws -> Void
    var inviteLink: @MainActor () async throws -> String
    var addByCode: @MainActor (_ code: String) async throws -> CodeOutcome
    var locate: @MainActor () async -> String?
    /// Uploads the picture and answers with where it now lives.
    var uploadPhoto: @MainActor (_ bytes: Data) async throws -> String?
    var finish: @MainActor () -> Void
}

extension OnboardingBackend {
    /// Clerk for the name and the photo, the Firstlight database for the rest.
    static let live = OnboardingBackend(
        saveProfile: { normalized in
            guard let user = NativeSession.shared.user else {
                throw NativeError.message("Sign in again to save your profile.")
            }
            @Dependency(\.network) var network
            let attributes = Clerk.shared.environment?.userSettings.attributes ?? [:]
            if attributes["first_name"]?.enabled == true, normalized.firstName != (user.firstName ?? "") {
                _ = try await user.update(.init(firstName: normalized.firstName))
            }
            // Onboarding only adds. A field left empty here is not a request
            // to clear one, so nothing written before, or on another Mac, is
            // lost to these steps.
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
        },
        saveSharing: { preset in
            @Dependency(\.network) var network
            let _: NativeSharingSettings = try await network.request(
                path: "/api/user/sharing", method: .patch, body: preset.settings
            )
            NotificationCenter.default.post(name: .init("FirstlightSharingChanged"), object: nil)
        },
        inviteLink: {
            @Dependency(\.network) var network
            let invite: NativePersonalInvite = try await network.request(path: "/api/user/invite-link", method: .get)
            guard !invite.personalInviteLink.isEmpty else {
                throw NativeError.message("Your invite link isn't ready yet.")
            }
            return invite.personalInviteLink
        },
        addByCode: { code in
            @Dependency(\.network) var network
            let result: NativeFriendRequestResult = try await network.request(
                path: "/api/friends/request", method: .post, body: ["inviteCode": code, "source": "code"]
            )
            let name = result.targetUser?.name ?? "your friend"
            return result.connected == true ? .connected(name) : .requested(name)
        },
        locate: { await OnboardingCityLookup.city() },
        uploadPhoto: { bytes in
            guard let user = NativeSession.shared.user else {
                throw NativeError.message("Sign in again to change your photo.")
            }
            @Dependency(\.network) var network
            _ = try await user.setProfileImage(imageData: bytes)
            try await network.syncNativeProfile()
            _ = try? await user.reload()
            return NativeSession.shared.user?.imageUrl
        },
        finish: {
            @Dependency(\.windowManager) var window
            window.handoffFromOnboarding()
        }
    )

    /// A rehearsal: long enough to see each label change; nothing is sent.
    static func pretend(finish: @escaping @MainActor () -> Void) -> OnboardingBackend {
        OnboardingBackend(
            saveProfile: { _ in try? await Task.sleep(for: .seconds(0.9)) },
            saveSharing: { _ in try? await Task.sleep(for: .seconds(0.5)) },
            inviteLink: { "https://firstlight.sh/join/REHEARSE" },
            addByCode: { _ in
                try? await Task.sleep(for: .seconds(0.7))
                return .requested("Alex")
            },
            locate: { await OnboardingCityLookup.city() },
            uploadPhoto: { _ in
                try? await Task.sleep(for: .seconds(0.9))
                return nil
            },
            finish: finish
        )
    }
}

/// The real path after Google: what the sign-in gave, what is still missing,
/// and the saves along the way to the menu bar. Welcome and the intro stay
/// with `LoginView`; this begins the moment the Firstlight profile is known.
@MainActor
final class OnboardingFlow: ObservableObject {
    // MARK: Lifecycle

    init(backend: OnboardingBackend = .live, stage: OnboardingStage = .shared) {
        self.backend = backend
        self.stage = stage
    }

    // MARK: Internal

    enum CodeState: Equatable {
        case idle
        case sending
        case failed(String)
        case done(OnboardingBackend.CodeOutcome)
    }

    static let shared = OnboardingFlow()

    @Published var draft = ProfileDraft()
    @Published var preset: OnboardingSharePreset = .everything
    @Published var code = ""
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var inviteLink: String?
    @Published private(set) var copied = false
    @Published private(set) var codeState: CodeState = .idle
    @Published private(set) var uploadingPhoto = false
    @Published private(set) var avatarURL: String?
    /// The photo was chosen here, rather than come with the sign-in.
    @Published private(set) var photoIsOwn = false
    /// A rehearsal: the steps run on empty fields and the saves are pretend,
    /// so the inputs can be tried without touching the account.
    @Published var rehearsal = false

    let stage: OnboardingStage

    /// The name is the draft's first name; the screens only ever show one.
    var name: String {
        get { self.draft.firstName }
        set { self.draft.firstName = newValue }
    }

    var hasName: Bool { !self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Something was done on the last chapter, so its button stops being a skip.
    var invited: Bool {
        // Someone who came by a friend's invitation already has their friend.
        if self.stage.inviter != nil { return true }
        if self.copied { return true }
        if case .done = self.codeState { return true }
        return false
    }

    /// What the one button says where the window is now.
    var buttonTitle: String {
        if self.error != nil { return "Retry" }
        switch self.stage.step {
        case .invite: return self.invited ? "Open Firstlight" : "Skip for now"
        default: return "Continue"
        }
    }

    var buttonLoadingTitle: String { "Saving…" }

    /// Sign-in is complete and `userInfo()` succeeded. Someone whose profile
    /// is already written has been here before, on this Mac or another, and
    /// goes straight to the menu bar; everyone else is shown around first.
    /// `about` is what the database holds, or nil when it could not be read:
    /// the fields then start empty, and the save only adds.
    func continueAfterSignIn(about: NativeProfileAbout?) {
        let user = NativeSession.shared.user
        self.error = nil
        self.avatarURL = user?.imageUrl
        self.draft = ProfileDraft(
            firstName: user?.firstName ?? "", lastName: user?.lastName ?? "", username: user?.username ?? "",
            location: about?.location ?? "", bio: about?.bio ?? "", website: about?.website ?? "",
            twitter: about?.twitter ?? "", telegram: about?.telegram ?? ""
        )
        let written = !self.draft.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if self.hasName, written {
            self.current.finish()
        } else {
            self.stage.advance(to: .day)
        }
    }

    /// Continue from Welcome during a rehearsal: the chapters, on empty fields.
    func startRehearsal() {
        self.error = nil
        self.draft = ProfileDraft()
        self.preset = .everything
        self.avatarURL = NativeSession.shared.user?.imageUrl
        self.stage.advance(to: .day)
    }

    /// The one button. A showing chapter opens its next row before it lets
    /// go; an asking one saves what it asked and only then moves.
    func next() {
        guard !self.saving else { return }
        let step = self.stage.step
        if self.stage.row < step.rows - 1 {
            self.stage.open(row: self.stage.row + 1)
            return
        }
        switch step {
        case .day: self.stage.advance(to: .friends)
        case .friends: self.stage.advance(to: .profile)
        case .profile: self.saveProfile { self.stage.advance(to: .privacy) }
        case .privacy: self.saveSharing()
        case .invite: self.current.finish()
        case .welcome,
             .handoff: break
        }
    }

    func back() {
        guard !self.saving else { return }
        self.error = nil
        let step = self.stage.step
        if self.stage.row > 0 {
            self.stage.open(row: self.stage.row - 1)
            return
        }
        guard let index = OnboardingStage.Step.chapters.firstIndex(of: step), index > 0 else { return }
        let previous = OnboardingStage.Step.chapters[index - 1]
        self.stage.advance(to: previous, row: max(previous.rows - 1, 0))
    }

    var canGoBack: Bool { self.stage.step != .day || self.stage.row > 0 }

    /// Close: enough has been seen. The one thing that cannot be skipped is a
    /// name, so without one Close lands on the profile instead of leaving.
    func close() {
        guard !self.saving else { return }
        self.error = nil
        if self.stage.step == .profile {
            // What is on the form is kept, not thrown away by leaving.
            self.saveProfile { self.current.finish() }
        } else if self.hasName {
            self.current.finish()
        } else {
            self.stage.advance(to: .profile)
        }
    }

    func jump(to step: OnboardingStage.Step) {
        guard !self.saving, step.isChapter, step <= self.stage.step else { return }
        self.error = nil
        self.stage.advance(to: step)
    }

    func locate() async -> String? { await self.current.locate() }

    /// The link is asked for as the last chapter comes in, so Copy is a copy.
    func prepareInvite() {
        guard self.inviteLink == nil else { return }
        Task { self.inviteLink = try? await self.current.inviteLink() }
    }

    func copyLink() {
        Task {
            do {
                let link: String
                if let known = self.inviteLink { link = known }
                else { link = try await self.current.inviteLink() }
                self.inviteLink = link
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                withAnimation(OnboardingStage.stepAnimation) { self.copied = true }
            } catch {
                withAnimation(OnboardingStage.stepAnimation) { self.codeState = .failed(error.localizedDescription) }
            }
        }
    }

    func addByCode() {
        let raw = self.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.codeState != .sending else { return }
        guard case let .friendCode(code)? = try? InviteInput.parse(raw) else {
            withAnimation(OnboardingStage.stepAnimation) {
                self.codeState = .failed("Enter a friend code or paste their link.")
            }
            return
        }
        self.codeState = .sending
        Task {
            do {
                let outcome = try await self.current.addByCode(code)
                withAnimation(OnboardingStage.stepAnimation) { self.codeState = .done(outcome) }
                if !self.rehearsal { await SocialStore.shared.refresh(force: true) }
            } catch {
                withAnimation(OnboardingStage.stepAnimation) {
                    self.codeState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func codeEdited() {
        if case .failed = self.codeState { self.codeState = .idle }
    }

    func choosePhoto() {
        guard !self.uploadingPhoto else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let before = (self.avatarURL, self.photoIsOwn)
        self.error = nil
        do {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 10_000_000 else { throw NativeError.message("Choose an image smaller than 10 MB.") }
            // The picture is on the face the moment it is chosen: a copy of
            // the file stands in until the upload has an address of its own,
            // so the choice is seen at once and not after a wait.
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("onboarding-photo-\(UUID().uuidString).\(url.pathExtension)")
            try bytes.write(to: local)
            withAnimation(OnboardingStage.stepAnimation) {
                self.avatarURL = local.absoluteString
                self.photoIsOwn = true
            }
            self.uploadingPhoto = true
            Task {
                defer { self.uploadingPhoto = false }
                do {
                    if let stored = try await self.current.uploadPhoto(bytes) { self.avatarURL = stored }
                } catch {
                    // Not kept: the face goes back to what it was.
                    withAnimation(OnboardingStage.stepAnimation) { (self.avatarURL, self.photoIsOwn) = before }
                    self.error = error.localizedDescription
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reset() {
        self.draft = ProfileDraft()
        self.preset = .everything
        self.code = ""
        self.saving = false
        self.error = nil
        self.inviteLink = nil
        self.copied = false
        self.codeState = .idle
        self.uploadingPhoto = false
        self.avatarURL = nil
        self.photoIsOwn = false
        self.rehearsal = false
    }

    // MARK: Private

    private let backend: OnboardingBackend

    private var current: OnboardingBackend {
        self.rehearsal ? .pretend(finish: self.backend.finish) : self.backend
    }

    /// Nothing typed is lost on failure; the button says Retry.
    private func saveProfile(then: @escaping @MainActor () -> Void) {
        guard self.hasName else {
            self.error = "Enter your name first."
            return
        }
        let normalized = self.draft.normalized
        guard normalized.errors.isEmpty else {
            self.error = "Check the highlighted fields."
            return
        }
        self.run {
            try await self.current.saveProfile(normalized)
            if !self.rehearsal { await SocialStore.shared.refresh(force: true) }
            then()
        }
    }

    private func saveSharing() {
        let preset = self.preset
        self.run {
            try await self.current.saveSharing(preset)
            self.stage.advance(to: .invite)
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        self.saving = true
        self.error = nil
        Task {
            defer { self.saving = false }
            do { try await work() }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// The steps after Welcome in the real onboarding window, on `OnboardingFlow`.
struct OnboardingFlowSteps: View {
    // MARK: Internal

    var body: some View {
        ZStack {
            if self.stage.step.isChapter {
                OnboardingChaptersView(flow: self.flow)
                    .transition(OnboardingStage.chapters)
            }
        }
        .animation(OnboardingStage.stepAnimation, value: self.stage.step.isChapter)
    }

    // MARK: Private

    @ObservedObject private var flow = OnboardingFlow.shared
    @ObservedObject private var stage = OnboardingStage.shared
}
