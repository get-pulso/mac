import SwiftUI

/// The button and its tray share only their surface. Text keeps its own size
/// while the capsule's frame grows into the card and returns on dismissal.
struct NativeTrayMorph {
    let id: String
    let namespace: Namespace.ID
    var isExpanded: Bool

    static func animation(isExpanded: Bool, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: isExpanded ? 0.24 : 0.18, bounce: 0)
    }
}

struct NativeTraySurface: ViewModifier {
    // MARK: Internal

    var morph: NativeTrayMorph?
    var prominent = false
    var backgroundMaterial: Material = .regular

    func body(content: Content) -> some View {
        content.background {
            // Keep the material in this view's own background. A shared glass
            // container also collects the list's scroll-edge bars and controls.
            if let morph, !reduceMotion {
                surface.matchedGeometryEffect(id: morph.id, in: morph.namespace)
                    .allowsHitTesting(false)
            } else {
                surface.allowsHitTesting(false)
            }
        }
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var surface: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                prominent ? AnyShapeStyle(Color.firstlight) :
                    reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) :
                    AnyShapeStyle(self.backgroundMaterial)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }
    }
}

/// Keeps the button's layout slot, but removes its geometry source while the
/// tray owns it. A hidden second source would make the shared frame ambiguous.
struct NativeTrayMorphButton<Label: View>: View {
    // MARK: Internal

    let morph: NativeTrayMorph
    var prominent = true
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                nativeButton.hidden().allowsHitTesting(false).accessibilityHidden(true)
            } else {
                buttonLabel.hidden().accessibilityHidden(true)
            }
            if !morph.isExpanded {
                restingButton
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .allowsHitTesting(!morph.isExpanded)
        .accessibilityHidden(morph.isExpanded)
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder private var restingButton: some View {
        if #available(macOS 26.0, *) {
            nativeButton
                .background {
                    if !reduceMotion {
                        // Register the native capsule's exact bounds without
                        // replacing its glass or collecting any neighbouring UI.
                        Color.clear
                            .matchedGeometryEffect(id: morph.id, in: morph.namespace)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            Button(action: action) { buttonLabel }
                .buttonStyle(NativeTrayMorphButtonStyle(morph: morph, prominent: prominent))
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder private var nativeButton: some View {
        if prominent {
            Button(action: action, label: label)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .tint(.firstlight)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        }
    }

    private var buttonLabel: some View {
        label()
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .contentShape(Capsule())
    }
}

private struct NativeTrayMorphButtonStyle: ButtonStyle {
    // MARK: Internal

    let morph: NativeTrayMorph
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(NativeTraySurface(morph: self.morph, prominent: self.prominent))
            .opacity(self.isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && !self.reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
}
