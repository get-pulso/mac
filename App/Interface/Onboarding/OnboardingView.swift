import SwiftUI

struct OnboardingFormExpandedKey: PreferenceKey {
    static var defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Both hosts render the same light. The proxy carries only the light; the
/// native window continues it into the original mark, then shows Welcome.
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
            let slot = RayLogoTiming.rect(in: panel.size)
            ZStack {
                if playback.shaderFailure == nil {
                    MetalOnboardingShaderView(
                        elapsed: Float(elapsed), inset: 0, nativeSurface: nativeSurface,
                        variant: playback.variant,
                        // An expanded form owns the whole window; the mark leaves the pane.
                        rayLogoRect: expandedForm ? slot.offsetBy(dx: 0, dy: -panel.height - slot.height) : slot,
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

                if nativeSurface {
                    welcome(size: panel.size, slot: slot)
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

    private func welcome(size: CGSize, slot: CGRect) -> some View {
        let time = self.playback.elapsed
        let compact = size.height < 538 || size.width < 748
        let titleAlpha = WelcomeTiming.titleOpacity(at: time)
        let buttonIn = WelcomeTiming.spring(time, after: WelcomeTiming.buttonStart)
        let buttonAlpha = WelcomeTiming.buttonOpacity(at: time)
        let enabled = time >= WelcomeTiming.interactiveAt

        return ZStack(alignment: .top) {
            VStack(spacing: compact ? 17 : 22) {
                // The mark itself is the shader's light; this only reserves its slot.
                Color.clear.frame(width: slot.width, height: slot.height).accessibilityHidden(true)
                Text("Welcome to Firstlight")
                    .font(.system(size: compact ? 38 : 48, weight: .medium))
                    .tracking(-1.8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .opacity(expandedForm ? 0 : titleAlpha)
                    .blur(radius: (1 - titleAlpha) * 2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHidden(expandedForm || titleAlpha < 1)
            }
            .frame(width: size.width)
            .offset(y: slot.minY)

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
}
