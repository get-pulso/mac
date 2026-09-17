import SwiftUI

/// One step of the onboarding after Welcome: the centre holds exactly one
/// thing, the footer holds the one button, both under the header that never
/// moves. The numbers are Welcome's own, so a step is laid out where the
/// title and the button already were.
struct OnboardingStepFrame<Content: View, Footer: View>: View {
    /// A click on the empty surface: the keyboard leaves whatever field had it.
    var onBackgroundTap: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let compact = size.height < 538 || size.width < 748
            ZStack {
                if let onBackgroundTap {
                    Color.clear.contentShape(Rectangle()).onTapGesture(perform: onBackgroundTap)
                }
                VStack(spacing: compact ? 10 : 14) { content() }
                    .frame(width: min(440, size.width - 64))
                    .offset(y: -(compact ? 22 : 30))
                VStack {
                    Spacer(minLength: 0)
                    VStack(spacing: 14) { footer() }
                        .frame(width: min(352, size.width - 64))
                        .padding(.bottom, compact ? 24 : 36)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .foregroundStyle(.white)
    }
}

/// The title of a step: a question, in the size Welcome's own title has.
struct OnboardingStepTitle: View {
    let text: String
    var size: CGFloat = 26

    var body: some View {
        Text(self.text)
            .font(.system(size: self.size, weight: .medium))
            .tracking(-1.0)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The same well the profile editor in Settings uses, so a field looks the
/// same on the first day as on every day after: `nativeFormField`, with its
/// corner radius, hairline and neutral focus. Only the type is larger here.
extension View {
    func onboardingField(focused: Bool) -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 15))
            .nativeFormField(focused: focused)
    }
}

/// The face the profile will have: the sign-in photo when there is one, the
/// first letter otherwise, a neutral figure before there is even a name.
struct OnboardingFace: View {
    var avatarURL: String?
    var name: String
    var size: CGFloat

    var body: some View {
        if self.name.trimmingCharacters(in: .whitespaces).isEmpty, self.avatarURL == nil {
            Circle().fill(.white.opacity(0.12))
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: self.size * 0.42, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(width: self.size, height: self.size)
                .accessibilityHidden(true)
        } else {
            FirstlightAvatar(url: self.avatarURL, name: self.name, size: self.size)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Name

/// Only when the sign-in gave no first name: one field, in focus from the
/// first frame, and the one button.
struct OnboardingNameStep: View {
    // MARK: Internal

    @Binding var name: String
    var avatarURL: String?
    let namespace: Namespace.ID
    var onContinue: () -> Void

    var body: some View {
        OnboardingStepFrame(onBackgroundTap: { self.focused = false }) {
            OnboardingFace(avatarURL: self.avatarURL, name: "", size: 64)
                .matchedGeometryEffect(id: OnboardingMorphID.face, in: self.namespace)
            OnboardingStepTitle(text: "What should we call you?", size: 32)
            TextField("First name", text: self.$name)
                .textContentType(.givenName)
                .focused(self.$focused)
                .onboardingField(focused: self.focused)
                .frame(width: 280)
                .multilineTextAlignment(.center)
                .accessibilityLabel("First name")
                .onSubmit { if self.canContinue { self.onContinue() } }
                .padding(.top, 6)
        } footer: {
            OnboardingContinueButton(isEnabled: self.canContinue, title: "Continue", action: self.onContinue)
        }
        .task { await OnboardingProfileChips.settle(); self.focused = true }
    }

    // MARK: Private

    @FocusState private var focused: Bool

    private var canContinue: Bool { !self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Things that travel between steps rather than being drawn twice.
enum OnboardingMorphID {
    static let face = "onboarding.face"
    static let name = "onboarding.name"
}

// MARK: - About

/// The centre of the onboarding: the question is the title, the placeholder
/// is an example, the field is live as soon as the step has arrived. A
/// location and links wait as small buttons under it and grow into fields
/// where they stand.
struct OnboardingAboutStep: View {
    // MARK: Internal

    @Binding var draft: ProfileDraft
    var name: String
    var avatarURL: String?
    let namespace: Namespace.ID
    var busy = false
    var error: String?
    /// Asks the system for the city. `nil` means it could not: the chip
    /// becomes a field instead of an explanation.
    var locate: () async -> String?
    var onSubmit: () -> Void

    var body: some View {
        OnboardingStepFrame(onBackgroundTap: {
            self.bioFocused = false
            self.release += 1
        }) {
            HStack(spacing: 8) {
                OnboardingFace(avatarURL: self.avatarURL, name: self.name, size: 28)
                    .matchedGeometryEffect(id: OnboardingMorphID.face, in: self.namespace)
                Text(self.name)
                    .font(.system(size: 14, weight: .medium))
                    .matchedGeometryEffect(id: OnboardingMorphID.name, in: self.namespace)
            }
            OnboardingStepTitle(text: "What are you working on?")
            VStack(alignment: .trailing, spacing: 6) {
                TextField(
                    "Building a design tool at 21st.dev, into climbing and generative art",
                    text: self.$draft.bio, axis: .vertical
                )
                .lineLimit(3 ... 6)
                .focused(self.$bioFocused)
                .onboardingField(focused: self.bioFocused)
                .accessibilityLabel("About you")
                .onSubmit(self.onSubmit)
                if self.draft.bio.count >= 200 {
                    Text("\(self.draft.bio.count) / \(ProfileDraft.bioLimit)")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(self.draft.bio.count > ProfileDraft.bioLimit ? Color.red : .white.opacity(0.5))
                        .transition(.opacity)
                }
            }
            .frame(width: 380)
            .animation(.easeOut(duration: 0.15), value: self.draft.bio.count >= 200)
            OnboardingProfileChips(draft: self.$draft, locate: self.locate, release: self.release) {
                self.bioFocused = false
            }
            .padding(.top, 4)
        } footer: {
            if let error {
                NativeInlineError(message: error).frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            OnboardingContinueButton(
                isLoading: self.busy, isEnabled: self.draft.errors[.bio] == nil,
                loadingTitle: "Saving…", title: self.buttonTitle, action: self.onSubmit
            )
        }
        // Focus starts the text system under the step's spring and drops
        // frames there (5 to 9 of about 16); after arrival, one or two.
        .task { await OnboardingStage.arrival(); self.bioFocused = true }
    }

    // MARK: Private

    @FocusState private var bioFocused: Bool
    @State private var release = 0

    /// The one button says the truth: nothing typed, and it is a skip.
    private var buttonTitle: String {
        if self.error != nil { return "Retry" }
        return self.draft.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Skip for now" : "Continue"
    }
}

// MARK: - Chips

/// What a chip stands for: one optional line of the profile.
enum OnboardingProfileChip: String, CaseIterable, Identifiable {
    case location, x, telegram, website

    // MARK: Internal

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .location: "Add location"
        case .x: "Add X"
        case .telegram: "Add Telegram"
        case .website: "Add website"
        }
    }

    var placeholder: String {
        switch self {
        case .location: "Your city"
        case .x,
             .telegram: "@username"
        case .website: "example.com"
        }
    }

    /// The chip's glyph: the same asset the profile draws the link with.
    @ViewBuilder var glyph: some View {
        switch self {
        case .location: NativeLocationIcon(size: 12)
        default:
            Image(self.assetImage).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 12, height: 12)
        }
    }

    var assetImage: String {
        switch self {
        case .location: "ProfileLocation"
        case .x: "ProfileX"
        case .telegram: "ProfileTelegram"
        case .website: "ProfileWebsite"
        }
    }

    /// Told what it holds, the field gets the right suggestions and not a
    /// one-time code from Messages.
    var contentType: NSTextContentType {
        switch self {
        case .location: .addressCity
        case .x,
             .telegram: .username
        case .website: .URL
        }
    }

    var field: ProfileDraft.Field {
        switch self {
        case .location: .location
        case .x: .twitter
        case .telegram: .telegram
        case .website: .website
        }
    }

    var keyPath: WritableKeyPath<ProfileDraft, String> {
        switch self {
        case .location: \.location
        case .x: \.twitter
        case .telegram: \.telegram
        case .website: \.website
        }
    }

    /// The chip, once filled, is the very line the profile will show.
    func display(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch self {
        case .location: return value
        case .x: return ProfileDraft.socialHandle(value, hosts: ["x.com", "twitter.com"]).map { "@\($0)" }
        case .telegram: return ProfileDraft.socialHandle(value, hosts: ["t.me", "telegram.me"]).map { "@\($0)" }
        case .website:
            guard let url = ProfileDraft.websiteURL(value), let host = url.host else { return nil }
            let path = url.path == "/" ? "" : url.path
            return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path
        }
    }
}

/// The row of small buttons under the About field. A press grows the button
/// into a field where it stands; Enter or leaving it shrinks the field back
/// into a chip that now carries the value. At most one is open.
struct OnboardingProfileChips: View {
    // MARK: Internal

    @Binding var draft: ProfileDraft
    var locate: () async -> String?
    /// Counts up when the surface around the chips is clicked: the open
    /// field commits and the keyboard is let go.
    var release = 0
    /// Called when a chip takes the keyboard, so the About field lets go.
    var onFocus: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(OnboardingProfileChip.allCases) { chip in
                    self.view(for: chip)
                }
            }
            if let message = self.invalid.flatMap({ self.draft.errors[$0.field] }) {
                NativeFormFieldError(message: message).transition(.opacity)
            }
        }
        .animation(
            NativeTrayMorph.animation(isExpanded: self.open != nil, reduceMotion: self.reduceMotion),
            value: self.open
        )
        .animation(.easeOut(duration: 0.15), value: self.invalid)
        .onChange(of: self.focused) { previous, current in
            if let previous, current != previous { self.commit(previous) }
            if current != nil { self.onFocus() }
        }
        .onChange(of: self.release) {
            if let open { self.commit(open) }
            self.focused = nil
        }
    }

    static func settle() async { try? await Task.sleep(for: .milliseconds(60)) }

    // MARK: Private

    @Namespace private var trays
    @State private var open: OnboardingProfileChip?
    @State private var invalid: OnboardingProfileChip?
    @State private var locating = false
    @State private var editing = ""
    @FocusState private var focused: OnboardingProfileChip?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    private func view(for chip: OnboardingProfileChip) -> some View {
        let morph = NativeTrayMorph(id: "chip.\(chip.id)", namespace: self.trays, isExpanded: self.open == chip)
        if self.open == chip {
            self.field(for: chip, morph: morph)
        } else if chip == .location, self.locating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(.white)
                Text("Finding your city…")
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).frame(minHeight: 32)
            .modifier(NativeTraySurface(morph: morph))
        } else {
            // While one chip is a field, the others step aside to their glyph.
            let aside = self.open != nil || self.locating
            NativeTrayMorphButton(morph: morph, prominent: false) {
                self.press(chip)
            } label: {
                HStack(spacing: 6) {
                    if let value = chip.display(self.draft[keyPath: chip.keyPath]) {
                        chip.glyph
                        if !aside { Text(value).lineLimit(1) }
                    } else if aside {
                        // Stepped aside, a chip still says which field it is.
                        chip.glyph
                    } else {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text(chip.title)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, aside ? 2 : 0)
            }
            .help(chip.display(self.draft[keyPath: chip.keyPath]) == nil ? chip.title : "Edit")
        }
    }

    private func field(for chip: OnboardingProfileChip, morph: NativeTrayMorph) -> some View {
        HStack(spacing: 6) {
            chip.glyph
                .foregroundStyle(.white.opacity(0.6))
            TextField(chip.placeholder, text: self.$editing)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .textContentType(chip.contentType)
                .autocorrectionDisabled()
                .focused(self.$focused, equals: chip)
                .onSubmit { self.commit(chip) }
                .onExitCommand { self.cancel(chip) }
                .accessibilityLabel(chip.title)
            if !self.editing.isEmpty {
                Button {
                    self.editing = ""
                    self.commit(chip)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }
        }
        .padding(.horizontal, 12).frame(width: 220, height: 32)
        .modifier(NativeTraySurface(morph: morph))
        // The field takes the keyboard once it is in the window, not while
        // it is still growing out of the button.
        .task { await Self.settle(); self.focused = chip }
    }

    /// Escape: the field goes back to what it was, as a chip.
    private func cancel(_ chip: OnboardingProfileChip) {
        guard self.open == chip else { return }
        self.invalid = nil
        self.open = nil
        self.focused = nil
    }

    private func press(_ chip: OnboardingProfileChip) {
        if let open { self.commit(open) }
        let current = self.draft[keyPath: chip.keyPath]
        if chip == .location, chip.display(current) == nil {
            self.locating = true
            Task {
                let city = await self.locate()
                self.locating = false
                if let city {
                    self.draft.location = city
                } else {
                    self.edit(chip)
                }
            }
            return
        }
        self.edit(chip)
    }

    private func edit(_ chip: OnboardingProfileChip) {
        self.editing = self.draft[keyPath: chip.keyPath]
        self.invalid = nil
        self.open = chip
    }

    /// Enter, a lost focus or another chip: the field becomes a chip again if
    /// the value is one, and stays a field with one line under it if not.
    private func commit(_ chip: OnboardingProfileChip) {
        guard self.open == chip else { return }
        self.draft[keyPath: chip.keyPath] = self.editing
        if self.draft.errors[chip.field] != nil {
            self.invalid = chip
            return
        }
        self.invalid = nil
        self.open = nil
        self.focused = nil
    }
}
