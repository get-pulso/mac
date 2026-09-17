import SwiftUI

extension View {
    /// Tapping this portrait opens the photograph on its own screen. For the
    /// places where the portrait is the subject — a profile — and not for rows,
    /// where a tap already means "open this person". A drawn placeholder has
    /// nothing inside it worth a screen, so it stays untappable.
    func opensPhoto(url: String?, action: (() -> Void)?) -> some View {
        modifier(ProfilePhotoOpener(url: url, action: action))
    }
}

private struct ProfilePhotoOpener: ViewModifier {
    let url: String?
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action, self.url?.isEmpty == false, !AvatarTile.isKnownDrawn(self.url) {
            content
                .contentShape(Circle())
                .onTapGesture(perform: action)
                .pointerStyle(.link)
                .help("Open photo")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            content
        }
    }
}
