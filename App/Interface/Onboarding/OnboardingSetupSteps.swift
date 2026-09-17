import SwiftUI

// MARK: - Shared pieces

/// The same well the profile editor in Settings uses, so a field looks the
/// same on the first day as on every day after: `nativeFormField`, with its
/// corner radius, hairline and neutral focus.
extension View {
    func onboardingField(focused: Bool) -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 14))
            .nativeFormField(focused: focused)
    }
}

/// The face the profile will have: the sign-in photo when there is one, the
/// first letter otherwise, a neutral figure before there is even a name. The
/// avatar itself turns the figure into the letter as the name is typed.
struct OnboardingFace: View {
    var avatarURL: String?
    var name: String
    var size: CGFloat

    var body: some View {
        FirstlightAvatar(url: self.avatarURL, name: self.name, size: self.size)
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
    }
}

/// The surface an asking chapter's controls sit on.
private struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { self.content() }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct OnboardingCardDivider: View {
    var body: some View { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
}

/// A small button beside a field, in the field's own corner so the two read
/// as one control. Prominent, it is the app's violet: the thing to do next.
private struct OnboardingChipButton<Label: View>: View {
    var busy = false
    var prominent = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: self.action) {
            // The wheel stands in the label's place rather than beside it, so
            // the button keeps its width and nothing next to it is pushed.
            HStack(spacing: 6) { self.label() }
                .opacity(self.busy ? 0 : 1)
                .overlay { if self.busy { ProgressView().controlSize(.mini).tint(.white) } }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).frame(height: 30)
            .background(
                self.prominent ? Color.firstlight : Color.white.opacity(0.1),
                in: RoundedRectangle(cornerRadius: NativeFormMetrics.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NativeFormMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(self.prominent ? 0.2 : 0.1), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: NativeFormMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(self.busy)
    }
}

// MARK: - The row friends will see

/// One row, the list's own, standing over the form that fills it. It is the
/// same card on the profile and on the privacy chapter: between them it
/// stays where it is and only what it says changes — the line about you
/// gives way to what you are doing, the time starts to count.
struct OnboardingYouCard: View {
    // MARK: Internal

    @ObservedObject var flow: OnboardingFlow
    /// At work, as the privacy chapter shows it; away, as the profile does.
    let live: Bool

    var body: some View {
        let name = self.flow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = self.flow.draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let bio = self.flow.draft.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                OnboardingGlyph(name: "OnboardingEye", size: 12)
                OnboardingMorphLabel(self.live ? "How friends see you while you work" : "How friends see you")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 10) {
                OnboardingFace(avatarURL: self.flow.avatarURL, name: name, size: 40)
                // With nothing under it the name stands level with the face;
                // a line arriving lifts it, a line leaving lets it back down.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if name.isEmpty {
                            Capsule().fill(.white.opacity(0.14)).frame(width: 64, height: 8)
                        } else {
                            Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        }
                        if !city.isEmpty {
                            HStack(spacing: 3) {
                                NativeLocationIcon().frame(width: 9)
                                Text(city)
                            }
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            .transition(.opacity.combined(with: .offset(x: -6)))
                        }
                    }
                    .frame(height: 17, alignment: .leading)
                    if self.live {
                        if self.flow.preset != .time {
                            NativePresenceLine(
                                appName: self.flow.preset == .everything ? "Cursor" : nil,
                                live: .init(
                                    session_count: 2, observed_at: "",
                                    tools: self.flow.preset == .everything
                                        ? [.init(tool: "claude_code", session_count: 2)] : nil
                                )
                            )
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                            .frame(height: 18, alignment: .leading)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                    } else if !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            .frame(height: 18, alignment: .leading)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(self.live ? "4h 21m" : "0m")
                    .font(.system(size: 16, weight: .medium)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            .environment(\.colorScheme, .dark)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .animation(OnboardingStage.stepAnimation, value: bio.isEmpty)
        .animation(OnboardingStage.stepAnimation, value: city.isEmpty)
        .animation(OnboardingStage.stepAnimation, value: self.flow.preset)
        .animation(OnboardingStage.stepAnimation, value: self.live)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of your row in a friend's list")
    }
}

// MARK: - Profile and privacy

/// The right side of the two chapters that ask about you. The card on top is
/// one view for both; under it, the form leaves and the three answers arrive.
struct OnboardingSetupColumn: View {
    // MARK: Internal

    @ObservedObject var flow: OnboardingFlow
    let step: OnboardingStage.Step

    var body: some View {
        VStack(spacing: 12) {
            OnboardingYouCard(flow: self.flow, live: self.step == .privacy)
            ZStack {
                if self.step == .privacy {
                    OnboardingPrivacyChoices(flow: self.flow).transition(self.stage.transition)
                } else {
                    OnboardingProfileForm(flow: self.flow).transition(self.stage.transition)
                }
            }
            // The taller of the two, so the card above stands still while
            // what is under it changes.
            .frame(minHeight: 240, alignment: .top)
        }
        .frame(maxWidth: 480)
        .frame(maxHeight: .infinity)
    }

    // MARK: Private

    @ObservedObject private var stage = OnboardingStage.shared
}

/// Everything at once, top to bottom, as a form is: the photo Google gave,
/// the name, a line, a city. Only the name is asked for; the rest can wait.
private struct OnboardingProfileForm: View {
    // MARK: Internal

    enum Field: Hashable { case name, about, city }

    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        OnboardingCard {
            self.row("Photo") {
                let missing = self.flow.avatarURL == nil
                // Without a photo the face itself asks for one: a plus on its
                // rim, and the whole face is the button.
                Button(action: self.flow.choosePhoto) {
                    OnboardingFace(avatarURL: self.flow.avatarURL, name: self.flow.name, size: 44)
                        .overlay(alignment: .bottomTrailing) {
                            if missing {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .frame(width: 16, height: 16)
                                    .background(Color.firstlight, in: Circle())
                                    .overlay(Circle().strokeBorder(Color(white: 0.17), lineWidth: 2))
                                    .offset(x: 2, y: 2)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(missing ? "Add a photo" : "Change photo")
                VStack(alignment: .leading, spacing: 2) {
                    Text(missing ? "Add a photo" : self.flow.photoIsOwn ? "Your photo" : "From your Google account")
                        .font(.system(size: 13, weight: missing ? .medium : .regular))
                        .foregroundStyle(.white.opacity(missing ? 0.92 : 0.5))
                    if missing {
                        Text("Friends spot a face faster than a letter.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                OnboardingChipButton(
                    busy: self.flow.uploadingPhoto, prominent: missing, action: self.flow.choosePhoto
                ) {
                    Text(missing ? "Choose photo…" : "Change…")
                }
                .animation(OnboardingStage.stepAnimation, value: missing)
            }
            OnboardingCardDivider()
            self.row("Name") {
                TextField("Your name", text: self.$flow.draft.firstName)
                    .textContentType(.givenName)
                    .focused(self.$focused, equals: .name)
                    .onboardingField(focused: self.focused == .name)
                    .onSubmit(self.flow.next)
                    .accessibilityLabel("Name")
            }
            OnboardingCardDivider()
            self.row("About") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField(
                        "Building a side project, mostly at night", text: self.$flow.draft.bio, axis: .vertical
                    )
                    .lineLimit(1 ... 3)
                    .focused(self.$focused, equals: .about)
                    .onboardingField(focused: self.focused == .about)
                    .onSubmit(self.flow.next)
                    .accessibilityLabel("About you")
                    if self.flow.draft.bio.count >= 200 {
                        Text("\(self.flow.draft.bio.count) / \(ProfileDraft.bioLimit)")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(
                                self.flow.draft.bio.count > ProfileDraft.bioLimit ? Color.red : .white.opacity(0.5)
                            )
                            .transition(.opacity)
                    }
                }
            }
            OnboardingCardDivider()
            self.row("City") {
                TextField("Your city", text: self.$flow.draft.location)
                    .textContentType(.addressCity)
                    .focused(self.$focused, equals: .city)
                    .onboardingField(focused: self.focused == .city)
                    .onSubmit(self.flow.next)
                    .accessibilityLabel("City")
                OnboardingChipButton(busy: self.locating, action: self.locate) {
                    NativeLocationIcon(size: 12)
                    Text("Locate")
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: self.flow.draft.bio.count >= 200)
        // Focus starts the text system under the chapter's spring and drops
        // frames there; after arrival it costs one or two.
        .task {
            await OnboardingStage.arrival()
            if !self.flow.hasName { self.focused = .name }
        }
    }

    // MARK: Private

    @FocusState private var focused: Field?
    @State private var locating = false

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 52, alignment: .leading)
            content()
        }
        .padding(.vertical, 10)
    }

    /// A refusal is not explained: the field simply takes the keyboard.
    private func locate() {
        guard !self.locating else { return }
        self.locating = true
        Task {
            let city = await self.flow.locate()
            self.locating = false
            if let city { self.flow.draft.location = city }
            else { self.focused = .city }
        }
    }
}

/// Three answers to one question. The chosen one is marked; the row above
/// shows at once what that choice looks like from the other side.
private struct OnboardingPrivacyChoices: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OnboardingCard {
                ForEach(Array(OnboardingSharePreset.allCases.enumerated()), id: \.element) { index, preset in
                    let chosen = self.flow.preset == preset
                    if index > 0 { OnboardingCardDivider() }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.title).font(.system(size: 14, weight: .medium))
                            Text(preset.detail)
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ZStack {
                            Circle().strokeBorder(.white.opacity(chosen ? 0 : 0.35), lineWidth: 1)
                            Circle().fill(Color.firstlight).scaleEffect(chosen ? 1 : 0.4).opacity(chosen ? 1 : 0)
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                .scaleEffect(chosen ? 1 : 0.2).opacity(chosen ? 1 : 0)
                        }
                        .frame(width: 20, height: 20)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.3, bounce: 0.35)) { self.flow.preset = preset }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 10, weight: .medium))
                Text("Window titles, prompts and file names are never recorded.")
            }
            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 18)
        }
    }
}

// MARK: - Invite

/// The last chapter: the link to send and a friend's code to enter, both in
/// sight. Whatever is done shows up under them as the row it will become.
struct OnboardingInviteColumn: View {
    // MARK: Internal

    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let inviter = self.stage.inviter {
                // Whoever sent the invitation is already in the list: the
                // chapter opens on the friend this person has, not on the
                // ones they have yet to find.
                HStack(spacing: 10) {
                    // No ring: whether they are at their Mac is not known here.
                    FirstlightAvatar(url: inviter.avatarURL, name: inviter.name, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            inviter.isGroup
                                ? "\(inviter.firstName) is waiting in \(inviter.destination)"
                                : "\(inviter.firstName) is already waiting for you"
                        )
                        .font(.system(size: 14, weight: .medium))
                        Text(inviter.isGroup ? "You're in the group." : "You're friends: first in your list.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .environment(\.colorScheme, .dark)
            }
            OnboardingCard {
                self.row("Link") {
                    // The window's own face and size: a link is a line of
                    // text here, not a line of code.
                    Text(self.flow.inviteLink.map(Self.bare) ?? "Preparing your link…")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(self.flow.inviteLink == nil ? 0.4 : 0.92))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    OnboardingChipButton(action: self.flow.copyLink) {
                        Image(systemName: self.flow.copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                        OnboardingMorphLabel(self.flow.copied ? "Copied" : "Copy")
                    }
                }
                OnboardingCardDivider()
                self.row("Code") {
                    TextField("A friend's code or link", text: self.$flow.code)
                        .autocorrectionDisabled()
                        .focused(self.$focused)
                        .onboardingField(focused: self.focused)
                        .onSubmit(self.flow.addByCode)
                        .onChange(of: self.flow.code) { self.flow.codeEdited() }
                        .accessibilityLabel("Friend code")
                    OnboardingChipButton(busy: self.flow.codeState == .sending, action: self.flow.addByCode) {
                        Text("Add")
                    }
                }
            }
            if case let .failed(message) = self.flow.codeState {
                Text(message).font(.system(size: 12)).foregroundStyle(Color.red.opacity(0.9))
                    .padding(.horizontal, 18)
                    .transition(.opacity)
            }
            if let outcome = self.outcome {
                HStack(spacing: 10) {
                    Group {
                        if let name = outcome.name {
                            FirstlightAvatar(url: nil, name: name, size: 40)
                        } else {
                            Circle().fill(.white.opacity(0.1))
                                .overlay { Image(systemName: "plus").font(.system(size: 14, weight: .medium)) }
                                .frame(width: 40, height: 40)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(outcome.title).font(.system(size: 13, weight: .medium))
                        Text(outcome.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .environment(\.colorScheme, .dark)
                .transition(.opacity.combined(with: .offset(y: 12)).combined(with: .blur))
            } else if self.stage.inviter == nil {
                Text("No one yet? The global Leaderboard is there from day one.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 18)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 480)
        .frame(maxHeight: .infinity)
        .animation(OnboardingStage.stepAnimation, value: self.flow.codeState)
        .animation(OnboardingStage.stepAnimation, value: self.flow.copied)
    }

    // MARK: Private

    private struct Outcome {
        let name: String?
        let title: String
        let detail: String
    }

    @FocusState private var focused: Bool
    @ObservedObject private var stage = OnboardingStage.shared

    private var outcome: Outcome? {
        if case let .done(result) = self.flow.codeState {
            switch result {
            case let .connected(name):
                return .init(name: name, title: name, detail: "You're friends now")
            case let .requested(name):
                return .init(name: name, title: "Request sent to \(name)", detail: "They'll be in your list once they accept")
            }
        }
        return nil
    }

    /// The link as it reads in a message: no scheme in front of it.
    private static func bare(_ link: String) -> String {
        link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 52, alignment: .leading)
            content()
        }
        .padding(.vertical, 10)
    }
}
