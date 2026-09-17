import SwiftUI

/// The button and its tray share only their surface. Text keeps its own size
/// while the capsule's frame grows into the card and returns on dismissal.
struct NativeTrayMorph {
    let id: String
    let namespace: Namespace.ID
    var isExpanded: Bool
    var usesGlass = true

    static func animation(isExpanded: Bool, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) :
            .spring(duration: isExpanded ? 0.24 : 0.18, bounce: 0)
    }
}

/// Contains just the floating source and destination, never the scrolling page.
struct NativeTrayMorphContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content() }
        } else {
            content()
        }
    }
}

struct NativeTraySurface: ViewModifier {
    // MARK: Internal

    var morph: NativeTrayMorph?
    var prominent = false
    var backgroundMaterial: Material = .regular

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), let morph, morph.usesGlass, !self.reduceTransparency {
            // The effect owns its foreground, so the material stays behind
            // the text while the shared glass identity changes its shape.
            content
                .glassEffect(
                    prominent ? .regular.tint(.firstlight).interactive() : .regular,
                    in: .rect(cornerRadius: 16)
                )
                .glassEffectID(reduceMotion ? nil : morph.id, in: morph.namespace)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        } else {
            content.background {
                if let morph, !reduceMotion {
                    surface.matchedGeometryEffect(id: morph.id, in: morph.namespace)
                        .allowsHitTesting(false)
                } else {
                    surface.allowsHitTesting(false)
                }
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
            buttonLabel.hidden().accessibilityHidden(true)
            if !morph.isExpanded {
                Button(action: action) { buttonLabel }
                    .buttonStyle(NativeTrayMorphButtonStyle(morph: morph, prominent: prominent))
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(!morph.isExpanded)
        .accessibilityHidden(morph.isExpanded)
    }

    // MARK: Private

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
