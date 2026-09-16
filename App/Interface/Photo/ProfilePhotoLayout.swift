import CoreGraphics
import Foundation

/// How big a portrait is drawn when it is shown as a picture rather than as an
/// avatar. Kept free of AppKit so the arithmetic — the part that goes wrong
/// quietly, by a point or two of stretch — can be checked without a screen.
enum ProfilePhotoLayout {
    /// What a pull sideways, or upwards, is worth. Enough that the picture
    /// answers the hand, far too little to be mistaken for a way out.
    static let pullResistance: CGFloat = 0.32

    /// The size a panel's height of pull costs the picture.
    static let pullShrink: CGFloat = 0.2

    /// A pull past this much of the panel closes the picture on its own. A
    /// fifth of the height: past it the photograph is visibly on its way out,
    /// and under it a hand that slipped still gets its picture back.
    static let pullCloseDistance: CGFloat = 70

    /// A throw closes it from anywhere past a flinch, in points and in points
    /// per second. Below these a twitch at the end of a click would count as
    /// one.
    static let pullFlickDistance: CGFloat = 14
    static let pullFlickSpeed: CGFloat = 420

    /// The room a photo screen has inside the popover: its width less the
    /// margin a screen carries, and its height less that margin and the header
    /// the Back button hangs in. Here rather than in the view, so the box the
    /// picture is fitted into can be checked along with the fitting.
    static var popoverBox: CGRect {
        let margin = NativeLayout.popoverContentPadding
        return CGRect(
            x: 0,
            y: 0,
            width: NativeLayout.popoverWidth - 2 * margin,
            height: NativeLayout.peopleBodyHeight + NativeLayout.popoverHeaderHeight
                - 2 * margin
                - (NativeLayout.popoverHeaderHeight - margin)
        )
    }

    /// The largest rect with the photo's own proportions that fits inside
    /// `bounds` once `inset` is taken off each side, centred there and aligned
    /// to the pixel grid so the edge of the picture stays crisp.
    ///
    /// `maxScale` is the ceiling in points per source pixel. A photo large
    /// enough to fill the space is limited by the space; only a small one
    /// reaches the ceiling, and for those the honest answer is a picture that
    /// stops growing rather than a wall of soft pixels.
    static func targetRect(
        imageSize: CGSize,
        in bounds: CGRect,
        inset: CGFloat,
        maxScale: CGFloat,
        pixelScale: CGFloat
    ) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0, maxScale > 0
        else { return nil }

        // An inset with no room left for it is a sign the space is small, not
        // a request for an empty rect: it gives up its share instead.
        let applied = max(0, min(inset, min(bounds.width, bounds.height) / 4))
        let available = bounds.insetBy(dx: applied, dy: applied)
        let fit = min(available.width / imageSize.width, available.height / imageSize.height)
        let scale = min(fit, maxScale)
        guard scale > 0 else { return nil }

        let step = pixelScale > 0 ? 1 / pixelScale : 1
        func align(_ value: CGFloat) -> CGFloat { (value / step).rounded() * step }

        let width = max(step, align(imageSize.width * scale))
        let height = max(step, align(imageSize.height * scale))
        return CGRect(
            x: align(bounds.midX - width / 2),
            y: align(bounds.midY - height / 2),
            width: width,
            height: height
        )
    }

    /// The corner of a portrait on its way out of an avatar. At the avatar's
    /// own size it is that circle exactly — anything less and the handover is
    /// a rounded square landing on a round portrait, which is the one mismatch
    /// nobody misses. It settles to `open` over the first hundred points of
    /// growth, so the rounding is done well before the picture is.
    static func cornerRadius(side: CGFloat, avatarSize: CGFloat, open: CGFloat) -> CGFloat {
        guard side > avatarSize else { return max(open, side / 2) }
        return max(open, avatarSize / 2 - (side - avatarSize) * 0.25)
    }

    /// How far a pull carries the picture. Down is where letting go leads, so
    /// down is followed exactly; the other three directions have nowhere to
    /// take it and are answered with resistance rather than with travel.
    static func pullTranslation(_ translation: CGSize) -> CGSize {
        CGSize(
            width: translation.width * self.pullResistance,
            height: translation.height > 0 ? translation.height : translation.height * self.pullResistance
        )
    }

    /// The picture gives up a fifth of itself over a panel's height of pull.
    /// It is what makes the pull read as the photograph leaving rather than
    /// as a picture sliding about the panel, and it is the first half of the
    /// fold back into the avatar: by the time the hand lets go the portrait
    /// is already on its way to being a circle again.
    static func pullScale(_ translation: CGSize, in bounds: CGRect) -> CGFloat {
        guard bounds.height > 0 else { return 1 }
        let travel = min(abs(translation.height) / bounds.height, 1)
        return 1 - travel * self.pullShrink
    }

    /// Whether letting go here closes the picture. Either it has been carried
    /// far enough that putting it back would be the surprise, or it was
    /// thrown: a flick covers almost no distance and still means go. Only
    /// downwards — a pull the picture resisted is not an instruction.
    static func pullCloses(translation: CGSize, velocity: CGSize) -> Bool {
        guard translation.height > 0 else { return false }
        if translation.height >= self.pullCloseDistance { return true }
        return translation.height >= self.pullFlickDistance && velocity.height >= self.pullFlickSpeed
    }

    /// The pixels a picture is actually made of. `NSImage.size` is points at
    /// whatever DPI the file claims, which for a photograph off a CDN is a
    /// guess; the representation knows.
    static func pixelSize(width: Int, height: Int, fallback: CGSize) -> CGSize {
        guard width > 0, height > 0 else { return fallback }
        return CGSize(width: width, height: height)
    }
}
