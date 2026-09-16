import SwiftUI

struct OnboardingFormExpandedKey: PreferenceKey {
    static var defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The proxy contains only the cloud; welcome content starts after native handoff.
struct OnboardingView: View {
    // MARK: Internal

    @ObservedObject var playback: IntroPlayback
    let nativeSurface: Bool
    let content: AnyView

    var body: some View {
        GeometryReader { proxy in
            let panel = nativeSurface ? CGRect(origin: .zero, size: proxy.size) : playback.panelRect
            let elapsed = nativeSurface ? IntroTiming.duration : playback.elapsed
            ZStack {
                if playback.shaderFailure == nil {
                    MetalOnboardingShaderView(
                        elapsed: Float(elapsed), inset: 0, nativeSurface: nativeSurface,
                        variant: 2, targetSize: panel.size,
                        targetOffset: CGPoint(
                            x: panel.midX - proxy.size.width / 2,
                            y: panel.midY - proxy.size.height / 2
                        ),
                        onFailure: playback.fail
                    ).accessibilityHidden(true)
                } else {
                    Rectangle().fill(Color(red: 0.37, green: 0.29, blue: 0.59))
                        .frame(width: panel.width, height: panel.height)
                        .position(x: panel.midX, y: panel.midY)
                }

                if nativeSurface {
                    welcome(size: panel.size)
                        .frame(width: panel.width, height: panel.height)
                        .position(x: panel.midX, y: panel.midY)
                }
            }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    // MARK: Private

    @State private var expandedForm = false

    private func welcome(size: CGSize) -> some View {
        let time = self.playback.welcomeElapsed
        let compact = size.height < 538 || size.width < 748
        let logoIn = WelcomeTiming.spring(time, after: WelcomeTiming.logoStart)
        let logoOut = WelcomeTiming.spring(time, after: WelcomeTiming.logoExitStart)
        let titleIn = WelcomeTiming.spring(time, after: WelcomeTiming.titleStart)
        let buttonIn = WelcomeTiming.spring(time, after: WelcomeTiming.buttonStart)
        let logoAlpha = WelcomeTiming.logoOpacity(at: time)
        let titleAlpha = WelcomeTiming.titleOpacity(at: time)
        let buttonAlpha = IntroTiming.smooth(WelcomeTiming.buttonStart, WelcomeTiming.interactiveAt, time)
        let enabled = time >= WelcomeTiming.interactiveAt

        return ZStack {
            Text("P")
                .font(.system(size: compact ? 88 : 100, weight: .semibold, design: .rounded))
                .scaleEffect(1 - logoOut * 0.08)
                .opacity(logoAlpha)
                .blur(radius: (1 - logoAlpha) * 10)
                .offset(y: (1 - logoIn) * 56 - logoOut * 64)
                .accessibilityHidden(true)

            Text("Welcome to Firstlight")
                .font(.system(size: compact ? 38 : 48, weight: .medium))
                .tracking(-1.8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .opacity(expandedForm ? 0 : titleAlpha)
                .blur(radius: (1 - titleAlpha) * 8)
                .offset(y: (1 - titleIn) * 40)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHidden(expandedForm || titleAlpha < 1)

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
        }
        .foregroundStyle(.white)
        .onPreferenceChange(OnboardingFormExpandedKey.self) { expandedForm = $0 }
    }
}
