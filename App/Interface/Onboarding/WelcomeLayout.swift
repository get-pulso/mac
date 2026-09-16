import AppKit

/// Where the mark and the name are at any moment of the welcome, from the
/// same clock the shader follows. The mark is drawn by the shader at the
/// rect this returns; the name is a SwiftUI text laid out beside it. Both
/// come from one set of numbers, so they never drift apart.
enum WelcomeLayout {
    // MARK: Internal

    /// A frozen frame of the choreography: everything the view needs to place
    /// the mark and the name.
    struct Frame {
        /// The shader's mark, in panel coordinates.
        var markRect: CGRect
        /// Where the name rests at this moment (the pair stays centred as it grows).
        var nameCenter: CGPoint
        var nameFontSize: CGFloat
        /// How far the name has come out from behind the mark, 0…1.
        var nameReveal: CGFloat
        /// Horizontal offset from `nameCenter`: negative while the name is still behind the mark.
        var nameSlide: CGFloat
        /// The name is only drawn right of this x (the mark's right edge), fading in over `nameFront`.
        var nameWindowLeft: CGFloat
        var nameFront: CGFloat
        var nameOpacity: Double
    }

    /// The header line the pair rises to, measured from the top.
    static let headerCenterY: CGFloat = 44
    /// The mark's size once the pair has risen into the header. The mark is
    /// held a little under the pair's own shrink, so the name reads as the
    /// header and the mark sits beside it rather than over it.
    static let headerMarkSide: CGFloat = 30
    /// What the name and the gap beside it shrink to in the header. The mark
    /// has its own header size, so this is not read from it.
    static let headerScale: CGFloat = 40 / RayLogoTiming.side
    static let gap: CGFloat = 16
    static let nameFontSize: CGFloat = 42
    static let nameTracking: CGFloat = -1.5
    static let nameWeight: NSFont.Weight = .medium
    /// Width of the soft transparent edge at the mark, where letters emerge.
    static let nameFront: CGFloat = 44

    /// The mark settles in the centre; the name slides out from behind it to
    /// the right through a soft transparent edge, last letters first, while
    /// the pair stays centred; then the pair rises to the header line and
    /// shrinks — the mark a little more than the name — and stays there.
    static func frame(at time: Double, in panel: CGSize) -> Frame {
        let reveal = CGFloat(WelcomeTiming.nameProgress(at: time))
        let rise = CGFloat(WelcomeTiming.riseProgress(at: time))
        let scale = 1 + (self.headerScale - 1) * rise
        let markScale = 1 + (self.headerMarkSide / RayLogoTiming.side - 1) * rise
        let centerY = panel.height / 2 + (self.headerCenterY - panel.height / 2) * rise
        let nameWidth = self.nameWidth * scale
        let markSide = RayLogoTiming.side * markScale
        let gapWidth = self.gap * scale
        let total = markSide + (gapWidth + nameWidth) * reveal
        let left = panel.width / 2 - total / 2
        let nameLeft = left + markSide + gapWidth
        // Starts entirely behind the mark, its right edge at the mark's right edge.
        let slide = -(nameWidth + gapWidth) * (1 - reveal)
        // The soft edge closes from its full width to the gap as the name
        // comes out, so the last letter still emerges softly and, once out,
        // nothing of the name stays faded.
        let front = (self.nameFront - (self.nameFront - self.gap) * reveal) * scale
        return Frame(
            markRect: CGRect(x: left, y: centerY - markSide / 2, width: markSide, height: markSide),
            nameCenter: CGPoint(x: nameLeft + nameWidth / 2, y: centerY),
            nameFontSize: self.nameFontSize * scale,
            nameReveal: reveal,
            nameSlide: slide,
            nameWindowLeft: left + markSide,
            nameFront: front,
            nameOpacity: 1
        )
    }

    // MARK: Private

    /// Measured once with the same font the view draws, so the pair is
    /// centred on the very first frame instead of after a layout pass.
    private static let nameWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: nameFontSize, weight: nameWeight)
        let text = NSAttributedString(string: "Firstlight", attributes: [.font: font, .kern: nameTracking])
        return ceil(text.size().width)
    }()
}
