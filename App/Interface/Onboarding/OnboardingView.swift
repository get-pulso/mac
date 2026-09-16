import SwiftUI

struct OnboardingFormExpandedKey: PreferenceKey {
    static var defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Both hosts render the same light. The proxy carries only the light; the
/// native window continues it into the original mark in the centre, reveals
/// the name beside it, lifts the pair into a header, and only then shows
/// Welcome: who is waiting, and one button.
struct OnboardingView: View {
    // MARK: Internal

    @ObservedObject var playback: IntroPlayback
    let nativeSurface: Bool
    let content: AnyView

    var body: some View {
        GeometryReader { proxy in
            let panel = nativeSurface ? CGRect(origin: .zero, size: proxy.size) : playback.panelRect
            let elapsed = playback.renderTime(nativeSurface: nativeSurface)
            // Derived from the panel, not measured: both hosts must agree on
            // the optical root from the very first frame, before Welcome exists.
            let frame = WelcomeLayout.frame(at: elapsed, in: panel.size)
            let slot = frame.markRect
            // Once the light has become the mark, a plain image of the asset
            // takes over in the same rect; the shader then holds a static,
            // markless frame and stops redrawing.
            let handover = nativeSurface ? WelcomeTiming.markImageProgress(at: elapsed) : 0
            let shaderElapsed = handover >= 1 ? WelcomeTiming.markImageVisibleAt : elapsed
            let offPane = slot.offsetBy(dx: 0, dy: -panel.height - slot.height)
            ZStack {
                if playback.shaderFailure == nil {
                    MetalOnboardingShaderView(
                        elapsed: Float(shaderElapsed), inset: 0, nativeSurface: nativeSurface,
                        variant: playback.variant,
                        // An expanded form owns the whole window; the mark leaves the pane.
                        rayLogoRect: expandedForm || handover >= 1 ? offPane : slot,
                        targetSize: panel.size,
                        targetOffset: CGPoint(
                            x: panel.midX - proxy.size.width / 2,
                            y: panel.midY - proxy.size.height / 2
                        ),
                        onFailure: playback.fail
                    ).accessibilityHidden(true)
                } else {
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: panel.width, height: panel.height)
                        .position(x: panel.midX, y: panel.midY)
                }

                if nativeSurface, handover > 0, !expandedForm, let mark = RayLogoImage.cropped {
                    Image(nsImage: mark)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: slot.width, height: slot.height)
                        .position(x: slot.midX, y: slot.midY)
                        .opacity(handover)
                        .accessibilityHidden(true)
                }

                if nativeSurface {
                    welcome(size: panel.size, frame: frame)
                        .frame(width: panel.width, height: panel.height)
                        .position(x: panel.midX, y: panel.midY)
                }
            }
        }
        // The intro is always dark, whatever the system appearance: one look.
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .task(id: session.pendingInvite) { await invite.load(session.pendingInvite) }
    }

    // MARK: Private

    @State private var expandedForm = false
    @StateObject private var invite = WelcomeInvite()
    @ObservedObject private var session = NativeSession.shared

    private func welcome(size: CGSize, frame: WelcomeLayout.Frame) -> some View {
        let time = self.playback.elapsed
        let compact = size.height < 538 || size.width < 748
        let titleAlpha = WelcomeTiming.titleOpacity(at: time)
        let titleIn = WelcomeTiming.spring(time, after: WelcomeTiming.titleStart)
        let subtitleAlpha = WelcomeTiming.subtitleOpacity(at: time)
        let subtitleIn = WelcomeTiming.spring(time, after: WelcomeTiming.subtitleStart)
        let buttonIn = WelcomeTiming.spring(time, after: WelcomeTiming.buttonStart)
        let buttonAlpha = WelcomeTiming.buttonOpacity(at: time)
        let enabled = time >= WelcomeTiming.interactiveAt
        let inviter = self.invite.inviter

        return ZStack {
            // The name, beside the shader's mark and on the same numbers: it
            // slides out from behind the mark through a soft transparent edge
            // at the mark's side, last letters first, rides up with the mark
            // and stays with it as the header.
            ZStack {
                Text("Firstlight")
                    .font(.system(size: frame.nameFontSize, weight: .medium))
                    .tracking(WelcomeLayout.nameTracking * frame.nameFontSize / WelcomeLayout.nameFontSize)
                    .fixedSize()
                    .position(x: frame.nameCenter.x + frame.nameSlide, y: frame.nameCenter.y)
            }
            .frame(width: size.width, height: size.height)
            .mask {
                let windowWidth = max(0, size.width - frame.nameWindowLeft)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: min(1, frame.nameFront / max(windowWidth, 1))),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: windowWidth, height: size.height)
                .position(x: frame.nameWindowLeft + windowWidth / 2, y: size.height / 2)
            }
            .opacity(expandedForm ? 0 : frame.nameOpacity)
            .accessibilityHidden(true)

            // Takes the centre once the pair has risen; they never overlap.
            // The title arrives first, its subtitle after it, one after another.
            VStack(spacing: compact ? 10 : 14) {
                VStack(spacing: compact ? 10 : 14) {
                    if let inviter {
                        FirstlightAvatar(url: inviter.avatarURL, name: inviter.name, size: compact ? 52 : 64)
                            .scaleEffect(0.3 + 0.7 * titleIn)
                            .accessibilityHidden(true)
                    }
                    Text(self.title(for: inviter))
                        .font(.system(size: self.titleSize(for: inviter, compact: compact), weight: .medium))
                        .tracking(-1.2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .accessibilityAddTraits(.isHeader)
                }
                .opacity(titleAlpha)
                .blur(radius: (1 - titleAlpha) * 8)
                .offset(y: (1 - titleIn) * 40)
                .accessibilityHidden(titleAlpha < 1)
                Text(self.subtitle(for: inviter))
                    .font(.system(size: compact ? 14 : 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .opacity(subtitleAlpha)
                    .blur(radius: (1 - subtitleAlpha) * 6)
                    .offset(y: (1 - subtitleIn) * 18)
                    .accessibilityHidden(subtitleAlpha < 1)
            }
            .offset(y: -(compact ? 22 : 30))
            .opacity(expandedForm ? 0 : 1)
            .accessibilityHidden(expandedForm)

            VStack {
                Spacer(minLength: 0)
                Group {
                    if expandedForm {
                        ScrollView { content.frame(maxWidth: .infinity) }
                            .scrollIndicators(.hidden)
                            .frame(height: max(180, size.height - 148))
                    } else {
                        content
                    }
                }
                .frame(width: min(352, size.width - 64))
                .opacity(buttonAlpha)
                .blur(radius: (1 - buttonAlpha) * 5)
                .offset(y: (1 - buttonIn) * 24)
                .allowsHitTesting(enabled)
                .disabled(!enabled)
                .accessibilityHidden(!enabled)
                .padding(.bottom, compact ? 24 : 36)
            }
            .frame(width: size.width, height: size.height)
        }
        .foregroundStyle(.white)
        .onPreferenceChange(OnboardingFormExpandedKey.self) { expandedForm = $0 }
    }

    private func title(for inviter: WelcomeInvite.Inviter?) -> String {
        // The name is already in the header.
        guard let inviter else { return "Welcome" }
        return inviter.isGroup ? "\(inviter.firstName) invited you to \(inviter.destination)" :
            "\(inviter.firstName) is waiting for you"
    }

    private func subtitle(for inviter: WelcomeInvite.Inviter?) -> String {
        // The line the site leads with, so the app and the front door agree.
        guard let inviter else { return "Think you\u{2019}re the most productive? Prove it." }
        return inviter.isGroup ? "Sign in to join them." : "Sign in and you'll be friends right away."
    }

    private func titleSize(for inviter: WelcomeInvite.Inviter?, compact: Bool) -> CGFloat {
        if inviter == nil { return compact ? 36 : 44 }
        return compact ? 26 : 32
    }
}
