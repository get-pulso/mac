import CoreGraphics
import Foundation

/// The arithmetic behind showing a portrait as a picture: how big it is drawn
/// inside the popover, and the URL it is asked for at that size. No windows
/// shown, no network, no accounts.
@main
struct ProfilePhotoChecks {
    static func main() {
        var checks = 0
        checks += self.checkPopoverBox()
        checks += self.checkTargetRect()
        checks += self.checkCornerRadius()
        checks += self.checkPull()
        checks += self.checkPhotoURL()
        print("""
        Profile photo checks passed: \(checks); \
        the room a photo has in the popover, fit and centring for square, portrait, panorama and tiny \
        photographs, the scale ceiling, pixel alignment at 1x and 2x, degenerate sizes, the corner on \
        the way out of the avatar, what a pull down is worth and when letting go of one closes the \
        picture, and Clerk sizing and placeholder detection.
        """)
    }

    // MARK: Private

    private static func checkPopoverBox() -> Int {
        let box = ProfilePhotoLayout.popoverBox
        // The panel is 350 wide and a screen in it is 405 tall; a screen keeps
        // a 14pt margin, and the photo screen also stays under the 50pt header
        // the Back button hangs in.
        precondition(box.width == 322, "The picture has the wrong width to work with: \(box.width)")
        precondition(box.height == 341, "The picture has the wrong height to work with: \(box.height)")
        precondition(box.origin == .zero, "The box is not where the screen starts: \(box.origin)")
        return 3
    }

    private static func checkTargetRect() -> Int {
        var checks = 0
        let box = ProfilePhotoLayout.popoverBox

        for pixelScale: CGFloat in [1, 2] {
            for size in [CGSize(width: 1024, height: 1024),
                         CGSize(width: 800, height: 1200),
                         CGSize(width: 4000, height: 200),
                         CGSize(width: 96, height: 96)] {
                guard let rect = ProfilePhotoLayout.targetRect(
                    imageSize: size, in: box, inset: 0, maxScale: 3, pixelScale: pixelScale
                ) else { preconditionFailure("No rect for \(size)") }

                precondition(
                    rect.width <= box.width + 0.5 && rect.height <= box.height + 0.5,
                    "The picture is larger than the screen holding it: \(rect) in \(box)"
                )
                // Its own proportions, to within the pixel the edges were
                // rounded to; a stretched face is the failure this guards.
                let wanted = size.width / size.height
                let got = rect.width / rect.height
                precondition(abs(wanted - got) < 0.01 * max(1, wanted), "Aspect drifted: \(wanted) vs \(got)")
                precondition(
                    abs(rect.midX - box.midX) <= 1 && abs(rect.midY - box.midY) <= 1,
                    "The picture is off centre: \(rect)"
                )
                // The grid the edges have to land on, or the border of the
                // picture is drawn half into a pixel and reads as blurred.
                let step = 1 / pixelScale
                for edge in [rect.minX, rect.minY, rect.width, rect.height] {
                    precondition(abs((edge / step).rounded() * step - edge) < 1e-9, "Off the pixel grid: \(edge)")
                }
                // Filling the panel with a 96px avatar is not a favour to
                // anyone: past the ceiling it stops growing.
                precondition(rect.width / size.width <= 3 + 1e-6, "Blown past the ceiling")
                checks += 5
            }
        }

        // A photograph big enough to fill the space is held by the space; a
        // small one is held by the ceiling.
        let big = ProfilePhotoLayout.targetRect(
            imageSize: CGSize(width: 2048, height: 2048), in: box, inset: 0, maxScale: 3, pixelScale: 2
        )
        precondition(big.map { abs($0.width - box.width) < 1 } == true, "A large photograph was not fitted")
        let small = ProfilePhotoLayout.targetRect(
            imageSize: CGSize(width: 96, height: 96), in: box, inset: 0, maxScale: 3, pixelScale: 2
        )
        precondition(small.map { abs($0.width - 288) < 1 } == true, "The ceiling was not applied")
        checks += 2

        // Nothing to place, nowhere to place it, or no growth allowed.
        precondition(ProfilePhotoLayout.targetRect(
            imageSize: .zero, in: box, inset: 0, maxScale: 3, pixelScale: 2
        ) == nil, "A photograph with no size was placed")
        precondition(ProfilePhotoLayout.targetRect(
            imageSize: CGSize(width: 10, height: 10), in: .zero, inset: 0, maxScale: 3, pixelScale: 2
        ) == nil, "A photograph was placed on nothing")
        precondition(ProfilePhotoLayout.targetRect(
            imageSize: CGSize(width: 10, height: 10), in: box, inset: 0, maxScale: 0, pixelScale: 2
        ) == nil, "A photograph was placed at no scale")
        checks += 3

        // An inset with no room for it gives up its share rather than leaving
        // an empty rect behind.
        guard let squeezed = ProfilePhotoLayout.targetRect(
            imageSize: CGSize(width: 400, height: 400),
            in: CGRect(x: 0, y: 0, width: 120, height: 90),
            inset: 400,
            maxScale: 3,
            pixelScale: 2
        ) else { preconditionFailure("A tight space got no rect") }
        precondition(squeezed.width > 0 && squeezed.height > 0, "Empty rect in a tight space")
        precondition(squeezed.width <= 120 && squeezed.height <= 90, "The rect escaped a tight space: \(squeezed)")
        checks += 2

        // What a picture is measured by: its pixels, falling back on the size
        // the file claims when it has no representation to ask.
        let fallback = CGSize(width: 7, height: 9)
        precondition(
            ProfilePhotoLayout.pixelSize(width: 900, height: 1200, fallback: fallback)
                == CGSize(width: 900, height: 1200),
            "Pixels were not preferred"
        )
        precondition(
            ProfilePhotoLayout.pixelSize(width: 0, height: 1200, fallback: fallback) == fallback,
            "An empty measurement was trusted"
        )
        checks += 2

        return checks
    }

    /// The corner on the way out of the avatar: a circle where the portrait
    /// was, a rounded picture where it ends, and never a rounded square landing
    /// on a round portrait in between.
    private static func checkCornerRadius() -> Int {
        let avatar: CGFloat = 76
        let open: CGFloat = 12

        let atRest = ProfilePhotoLayout.cornerRadius(side: avatar, avatarSize: avatar, open: open)
        precondition(abs(atRest - avatar / 2) < 0.001, "The handover is not a circle: \(atRest)")
        // Smaller than the avatar it left — the way back, at its last frames.
        let shrunk = ProfilePhotoLayout.cornerRadius(side: 40, avatarSize: avatar, open: open)
        precondition(abs(shrunk - 20) < 0.001, "A shrinking portrait is not a circle: \(shrunk)")

        let opened = ProfilePhotoLayout.cornerRadius(side: 322, avatarSize: avatar, open: open)
        precondition(abs(opened - open) < 0.001, "The picture did not settle to its own corner: \(opened)")
        // Done rounding well before the picture is done growing.
        let partway = ProfilePhotoLayout.cornerRadius(side: 190, avatarSize: avatar, open: open)
        precondition(abs(partway - open) < 0.001, "The corner is still travelling at 190pt: \(partway)")

        var previous = CGFloat.greatestFiniteMagnitude
        for side in stride(from: CGFloat(76), through: 322, by: 2) {
            let radius = ProfilePhotoLayout.cornerRadius(side: side, avatarSize: avatar, open: open)
            precondition(radius <= previous + 0.001, "The corner grew back at \(side)")
            precondition(radius >= open - 0.001, "The corner went under its own floor at \(side)")
            precondition(radius <= side / 2 + 0.001, "The corner is larger than the shape at \(side)")
            previous = radius
        }
        return 4 + 3 * 124
    }

    /// Pulling the picture down: what the hand is answered with, and what
    /// letting go means. The picture follows a pull down and only leans the
    /// other ways; it closes once carried a fifth of the panel or thrown, and
    /// never for a pull it resisted.
    private static func checkPull() -> Int {
        let box = ProfilePhotoLayout.popoverBox
        var checks = 0

        // Down is followed point for point; the three directions with nowhere
        // to go move a fraction of the way and no further.
        let down = ProfilePhotoLayout.pullTranslation(CGSize(width: 0, height: 120))
        precondition(abs(down.height - 120) < 0.001, "A pull down was not followed: \(down)")
        let up = ProfilePhotoLayout.pullTranslation(CGSize(width: 0, height: -120))
        precondition(abs(up.height) < 120 * 0.5, "A pull up was not resisted: \(up)")
        let sideways = ProfilePhotoLayout.pullTranslation(CGSize(width: 120, height: 0))
        precondition(sideways.width > 0 && sideways.width < 120 * 0.5, "A pull sideways was not resisted")
        precondition(ProfilePhotoLayout.pullTranslation(.zero) == .zero, "A hand at rest moved the picture")
        checks += 4

        // The size goes with the distance, one way, and stops where the
        // picture is still a picture.
        precondition(abs(ProfilePhotoLayout.pullScale(.zero, in: box) - 1) < 0.001, "The picture shrank at rest")
        var previous: CGFloat = 1.001
        for height in stride(from: CGFloat(0), through: box.height * 2, by: 10) {
            let scale = ProfilePhotoLayout.pullScale(CGSize(width: 0, height: height), in: box)
            precondition(scale <= previous + 0.001, "The picture grew while being pulled at \(height)")
            precondition(scale >= 1 - ProfilePhotoLayout.pullShrink - 0.001, "The picture shrank past its floor")
            previous = scale
        }
        precondition(
            abs(ProfilePhotoLayout.pullScale(CGSize(width: 0, height: box.height), in: box)
                - (1 - ProfilePhotoLayout.pullShrink)) < 0.001,
            "A panel's worth of pull did not cost the picture its fifth"
        )
        // A height of nothing is a screen that has not been laid out yet, not
        // an invitation to divide by it.
        precondition(
            ProfilePhotoLayout.pullScale(CGSize(width: 0, height: 40), in: .zero) == 1,
            "The picture was scaled against an empty screen"
        )
        checks += 4

        // Letting go: far enough, or thrown. Never upwards, and never on the
        // twitch at the end of a click.
        let still = CGSize.zero
        precondition(
            ProfilePhotoLayout.pullCloses(translation: CGSize(width: 0, height: 120), velocity: still),
            "A picture carried past the threshold stayed"
        )
        precondition(
            !ProfilePhotoLayout.pullCloses(translation: CGSize(width: 0, height: 40), velocity: still),
            "A picture that was barely moved left"
        )
        precondition(
            ProfilePhotoLayout.pullCloses(
                translation: CGSize(width: 0, height: 30),
                velocity: CGSize(width: 0, height: 900)
            ),
            "A thrown picture stayed"
        )
        precondition(
            !ProfilePhotoLayout.pullCloses(
                translation: CGSize(width: 0, height: 4),
                velocity: CGSize(width: 0, height: 900)
            ),
            "A flinch at the end of a click closed the picture"
        )
        precondition(
            !ProfilePhotoLayout.pullCloses(
                translation: CGSize(width: 0, height: -200),
                velocity: CGSize(width: 0, height: -900)
            ),
            "A pull upwards, which the picture resisted, closed it"
        )
        precondition(
            !ProfilePhotoLayout.pullCloses(
                translation: CGSize(width: 200, height: 0),
                velocity: CGSize(width: 900, height: 0)
            ),
            "A pull sideways closed the picture"
        )
        checks += 6

        // The threshold is a distance a hand crosses on purpose and a picture
        // survives: well inside the panel, well past a slip.
        precondition(
            ProfilePhotoLayout.pullCloseDistance > 40 && ProfilePhotoLayout.pullCloseDistance < box.height / 3,
            "The way out is either too easy or too far: \(ProfilePhotoLayout.pullCloseDistance)"
        )
        checks += 1

        return checks
    }

    private static func checkPhotoURL() -> Int {
        var checks = 0

        let plain = "https://img.clerk.com/\(self.token(#"{"type":"proxy","src":"https://example.com/a.jpg"}"#))"
        guard let sized = ProfilePhotoURL.sized(plain, width: 1024) else { preconditionFailure("No sized URL") }
        precondition(sized.query?.contains("width=1024") == true, "No width asked for: \(sized)")
        precondition(sized.query?.contains("quality=90") == true, "No quality asked for: \(sized)")
        precondition(!ProfilePhotoURL.isPlaceholder(plain), "An uploaded photograph was taken for a placeholder")
        checks += 3

        // A row asks for a small square crop; the photo screen has to undo all
        // of it, not add a second width beside the first.
        let cropped = plain + "?width=96&height=96&fit=crop"
        guard let recropped = ProfilePhotoURL.sized(cropped, width: 1024) else { preconditionFailure("No resized URL") }
        let query = recropped.query ?? ""
        precondition(!query.contains("width=96"), "The thumbnail's width survived: \(query)")
        precondition(!query.contains("height=") && !query.contains("fit="), "The square crop survived: \(query)")
        precondition(query.contains("width=1024"), "No width asked for: \(query)")
        checks += 3

        // Somewhere else entirely: passed through exactly as it came.
        let other = "https://example.com/avatar.png?size=64"
        precondition(
            ProfilePhotoURL.sized(other, width: 1024)?.absoluteString == other,
            "A URL that is not Clerk's was rewritten"
        )
        precondition(!ProfilePhotoURL.isPlaceholder(other), "A URL that is not Clerk's was read as a placeholder")
        precondition(ProfilePhotoURL.sized(nil, width: 1024) == nil, "Nothing became a URL")
        precondition(ProfilePhotoURL.sized("", width: 1024) == nil, "An empty string became a URL")
        precondition(!ProfilePhotoURL.isPlaceholder(nil), "Nothing was read as a placeholder")
        checks += 5

        // An account with no photograph: Clerk draws the initials itself, and
        // there is nothing inside that worth a screen.
        let initials = "https://img.clerk.com/\(self.token(#"{"type":"default","initials":"SK"}"#))?width=96"
        precondition(ProfilePhotoURL.isPlaceholder(initials), "A drawn placeholder was offered as a photograph")
        checks += 1

        return checks
    }

    /// The payload Clerk signs into the path: base64url, and padded only when
    /// it happens to land on a boundary.
    private static func token(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
