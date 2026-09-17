import AppKit
import SwiftUI

/// A portrait's one letter, in the app's rounded face, centred by its ink.
/// SwiftUI centres a line of type — its advance across, ascender to descender
/// down — and inside a circle that shows: a capital sits a little low, and a
/// letter whose sides differ, a D or a Я, leans to one of them. The letter is
/// moved so that its own shape is what sits in the middle.
struct AvatarLetter: View {
    // MARK: Internal

    let letter: String
    let size: CGFloat

    var body: some View {
        let offset = Self.inkOffset(of: self.letter, size: self.size)
        Text(self.letter)
            .font(.system(size: self.size, weight: .medium, design: .rounded))
            .offset(x: offset.width, y: offset.height)
    }

    /// How far the letter moves so that its ink, not its line, is centred.
    /// The font measures upwards from the baseline and the screen downwards,
    /// so ink lying below the middle of the line — a negative distance there —
    /// is the same number as the way up on screen.
    @MainActor static func inkOffset(of letter: String, size: CGFloat) -> CGSize {
        let key = "\(letter) \(size)"
        if let known = self.offsets[key] { return known }

        let system = NSFont.systemFont(ofSize: size, weight: .medium)
        let font = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: letter, attributes: [.font: font]))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let offset = ink.isNull || ink.isEmpty ? .zero : CGSize(
            width: advance / 2 - ink.midX,
            height: ink.midY - (font.ascender + font.descender) / 2
        )
        self.offsets[key] = offset
        return offset
    }

    // MARK: Private

    /// Rows draw the same few letters at the same few sizes over and over.
    @MainActor private static var offsets = [String: CGSize]()
}
