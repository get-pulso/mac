import AppKit
import Nuke
import NukeUI
import SwiftUI

/// A portrait on a screen of its own: the whole photograph, not the circle a
/// row crops a face into. It opens out of the avatar on the profile and settles
/// back into it, so it reads as that picture growing rather than as another
/// screen arriving. The header's Back button leads out — the same Back every
/// other screen in the popover has — and so does pulling the picture down and
/// letting go of it, which is the way out that is already under the hand.
struct ProfilePhotoScreen: View {
    // MARK: Internal

    /// Shared geometry with the portrait this was opened from. Without it the
    /// picture simply fades in, which is what a machine set to keep still asks
    /// for.
    struct Morph {
        let id: String
        let namespace: Namespace.ID
    }

    let url: String?
    let name: String
    var morph: Morph?
    /// The circle the picture leaves, and comes back to.
    var avatarSize: CGFloat = 76
    /// Leads out of the picture, as Back does. A pull calls it: the
    /// photograph is dragged off the panel, let go, and folds into the avatar
    /// from there.
    var close: (() -> Void)?

    var body: some View {
        LazyImage(url: ProfilePhotoURL.sized(self.url, width: Self.openWidth)) { state in
            if let image = state.imageContainer?.image {
                self.picture(image)
            } else if let thumbnail {
                // The picture the row already drew, held at the size the
                // photograph will take: the screen has the right image on it
                // from the first frame, and only gets sharper.
                self.picture(thumbnail)
            } else {
                self.waiting
            }
        }
        // The whole room a screen has, whatever shape the photograph is, so
        // the panel is the same height with a portrait on it as it was with
        // the profile: the picture opens, the window does not move.
        .frame(width: self.box.width, height: self.box.height)
        // The pull is taken by the screen, which holds still, rather than by
        // the picture, which is the thing being moved.
        .contentShape(Rectangle())
        .gesture(self.pullGesture, isEnabled: self.close != nil)
        .accessibilityElement()
        .accessibilityLabel(self.name.isEmpty ? "Photo" : "Photo of \(self.name)")
    }

    // MARK: Private

    /// Wide enough for any screen this opens on, and the size Clerk's CDN will
    /// render down to from the original without being asked twice.
    private static let openWidth = 1024

    /// The picture is the screen; the rounding is only there to keep it from
    /// reading as a poster stuck on the panel.
    private static let openCornerRadius: CGFloat = 12

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the hand has carried the picture. It moves the picture by
    /// moving its frame rather than by drawing it elsewhere, so the portrait's
    /// shared geometry goes with it: let go, and the fold back into the avatar
    /// starts from where the picture actually is rather than from the middle
    /// of a panel it left a moment ago.
    @State private var pull: CGSize = .zero

    private var box: CGRect { ProfilePhotoLayout.popoverBox }

    /// The way out that is already under the hand. Down is the direction with
    /// somewhere to go: the picture follows it point for point, gives up a
    /// little size on the way, and past a fifth of the panel — or thrown, at
    /// any distance — letting go closes it. Anything short of that is a hand
    /// that changed its mind, and the picture springs back.
    private var pullGesture: some Gesture {
        // Measured against the screen, not against the picture: the picture is
        // what the pull moves, so a drag reported in its own coordinates has
        // the hand chasing a ruler that keeps sliding out from under it — at a
        // slow pull that reads as the photograph shaking in place.
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                self.pull = ProfilePhotoLayout.pullTranslation(value.translation)
            }
            .onEnded { value in
                if let close, ProfilePhotoLayout.pullCloses(translation: value.translation, velocity: value.velocity) {
                    close()
                } else {
                    withAnimation(
                        self.reduceMotion
                            ? .easeOut(duration: 0.18)
                            : .spring(duration: 0.34, bounce: 0.22)
                    ) { self.pull = .zero }
                }
            }
    }

    private var thumbnail: NSImage? {
        self.url.flatMap { URL(string: $0) }.flatMap { ImagePipeline.shared.cache[$0]?.image }
    }

    private var waiting: some View {
        let side = min(self.box.width, self.box.height)
        return RoundedRectangle(cornerRadius: Self.openCornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(width: side, height: side)
            .overlay { ProgressView().controlSize(.small) }
    }

    @ViewBuilder private func picture(_ image: NSImage) -> some View {
        let rect = self.rect(for: image)
        let scale = ProfilePhotoLayout.pullScale(self.pull, in: self.box)
        // The frame decides the size and the photo fills it. The frame is cut
        // to the picture's own proportions, so filling it crops nothing — and
        // on the way out of the circle, where the frame is still the avatar's
        // square, it crops exactly the way the avatar did.
        let framed = Color.clear
            .overlay { Image(nsImage: image).resizable().scaledToFill() }

        // The shared geometry sits under the fixed frame: above it the size
        // would be pinned and only the position would travel. The corner is
        // read from the rect the clip is handed, which is the flying one, so
        // the circle opens in step with the picture rather than on a timer of
        // its own.
        Group {
            if let morph {
                framed
                    .matchedGeometryEffect(id: morph.id, in: morph.namespace)
                    .frame(width: rect.width * scale, height: rect.height * scale)
            } else {
                framed.frame(width: rect.width * scale, height: rect.height * scale)
            }
        }
        .clipShape(OpeningCorners(avatarSize: self.avatarSize, open: Self.openCornerRadius))
        // The thumbnail and the photograph can disagree about their
        // proportions; the frame settles rather than jumping when the larger
        // one lands.
        .animation(.snappy(duration: 0.2, extraBounce: 0), value: rect)
        // `position`, not `offset`: an offset is drawn somewhere else and laid
        // out where it always was, and the flight home would then set off from
        // a picture nobody is looking at. This moves the frame itself.
        .position(
            x: self.box.width / 2 + self.pull.width,
            y: self.box.height / 2 + self.pull.height
        )
    }

    private func rect(for image: NSImage) -> CGRect {
        let pixels = image.representations.first.map {
            ProfilePhotoLayout.pixelSize(width: $0.pixelsWide, height: $0.pixelsHigh, fallback: image.size)
        } ?? image.size
        let side = min(self.box.width, self.box.height)
        return ProfilePhotoLayout.targetRect(
            imageSize: pixels,
            in: self.box,
            inset: 0,
            // Points per source pixel. Reached only by a portrait too small to
            // fill the panel, and past this one it is mush rather than a face.
            maxScale: 3,
            pixelScale: self.displayScale
        ) ?? CGRect(x: 0, y: 0, width: side, height: side)
    }
}

/// A circle at the avatar's size, a rounded picture at the photograph's. It
/// takes its radius from the rect it is drawn in rather than from a number
/// animating beside it, so it cannot fall out of step with the flight.
private struct OpeningCorners: Shape {
    let avatarSize: CGFloat
    let open: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: ProfilePhotoLayout.cornerRadius(
            side: min(rect.width, rect.height),
            avatarSize: self.avatarSize,
            open: self.open
        ))
    }
}
