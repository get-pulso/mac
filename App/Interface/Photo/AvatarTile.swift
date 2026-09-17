import AppKit
import os

/// A picture drawn for someone who has no photograph. Clerk marks its own in
/// the URL; Google's letter squares arrive looking like any other photo and can
/// only be told apart by what is in them. Either way the portrait draws the
/// app's own letter instead, so a person without a photo looks the same
/// whoever signed them in.
enum AvatarTile {
    // MARK: Internal

    /// Whether the portrait at `raw` is a drawn one. Clerk's is known from the
    /// address alone; a picture Google supplied is read once it has loaded, and
    /// the verdict is kept by address, so a row drawn again while the list
    /// scrolls costs a lookup rather than another look at the pixels.
    static func isDrawn(_ raw: String?, image: NSImage?) -> Bool {
        guard let raw else { return false }
        if ProfilePhotoURL.isPlaceholder(raw) { return true }
        guard ProfilePhotoURL.isFromGoogle(raw) else { return false }
        if let known = self.verdicts.withLock({ $0[raw] }) { return known }
        guard let image, let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return false }

        let verdict = self.isLetter(picture)
        self.verdicts.withLock { $0[raw] = verdict }
        return verdict
    }

    /// What is known without the picture in hand: Clerk's tile by its address,
    /// Google's once something has loaded it and looked.
    static func isKnownDrawn(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return ProfilePhotoURL.isPlaceholder(raw) || self.verdicts.withLock { $0[raw] } == true
    }

    /// One flat coloured ground holding a white letter, read at 32 pixels a
    /// side: small enough to cost a millisecond, large enough that the letter
    /// is still a shape and not a smudge.
    static func isLetter(_ image: CGImage) -> Bool {
        guard let pixels = self.pixels(of: image) else { return false }
        return self.isLetter(rgba: pixels)
    }

    /// The same reading over pixels already reduced: RGBA, eight bits each.
    ///
    /// The ground is the commonest colour, and it has to cover most of the
    /// picture — a letter takes a tenth of it, a subject in front of a plain
    /// backdrop far more. Nearly everything else has to lie between that ground
    /// and white, where a letter and its soft edge do and skin, shadow and a
    /// second colour do not. The ground itself has to be a colour dark enough
    /// to hold white type: a black-and-white photograph against a dark
    /// backdrop is otherwise, pixel for pixel, a ground and shades towards white.
    static func isLetter(rgba: [UInt8]) -> Bool {
        let count = rgba.count / 4
        var bins = [Int: Int]()
        for index in 0 ..< count {
            bins[self.bin(rgba, index), default: 0] += 1
        }
        guard let top = bins.max(by: { $0.value < $1.value }) else { return false }

        var red = 0.0, green = 0.0, blue = 0.0
        for index in 0 ..< count where self.bin(rgba, index) == top.key {
            red += Double(rgba[index * 4])
            green += Double(rgba[index * 4 + 1])
            blue += Double(rgba[index * 4 + 2])
        }
        red /= Double(top.value)
        green /= Double(top.value)
        blue /= Double(top.value)

        let towardsWhite = (red: 255 - red, green: 255 - green, blue: 255 - blue)
        let span = max(
            towardsWhite.red * towardsWhite.red + towardsWhite.green * towardsWhite.green
                + towardsWhite.blue * towardsWhite.blue,
            1
        )
        var ground = 0, elsewhere = 0
        for index in 0 ..< count {
            let dr = Double(rgba[index * 4]) - red
            let dg = Double(rgba[index * 4 + 1]) - green
            let db = Double(rgba[index * 4 + 2]) - blue
            if dr * dr + dg * dg + db * db <= 24 * 24 { ground += 1 }
            let along = min(
                1,
                max(0, (dr * towardsWhite.red + dg * towardsWhite.green + db * towardsWhite.blue) / span)
            )
            let er = dr - along * towardsWhite.red
            let eg = dg - along * towardsWhite.green
            let eb = db - along * towardsWhite.blue
            if er * er + eg * eg + eb * eb > 32 * 32 { elsewhere += 1 }
        }

        let chroma = max(red, green, blue) - min(red, green, blue)
        let luminance = 0.2126 * self.linear(red) + 0.7152 * self.linear(green) + 0.0722 * self.linear(blue)
        return Double(ground) >= 0.6 * Double(count)
            && Double(elsewhere) <= 0.03 * Double(count)
            && chroma >= 20
            && luminance >= 0.02 && luminance <= 0.5
    }

    // MARK: Private

    private static let side = 32

    private static let verdicts = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// The picture filling a square of `side` pixels, cropped to its middle
    /// the way a round portrait crops it.
    private static func pixels(of image: CGImage) -> [UInt8]? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = CGFloat(self.side)
        let scale = max(side / width, side / height)
        let rect = CGRect(
            x: (side - width * scale) / 2,
            y: (side - height * scale) / 2,
            width: width * scale,
            height: height * scale
        )

        var pixels = [UInt8](repeating: 0, count: self.side * self.side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: self.side,
                height: self.side,
                bitsPerComponent: 8,
                bytesPerRow: self.side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            return true
        }
        return drawn ? pixels : nil
    }

    /// Four bits a channel: near enough that the ground's own grain lands in
    /// one bin, far enough that a letter's edge does not.
    private static func bin(_ rgba: [UInt8], _ index: Int) -> Int {
        Int(rgba[index * 4] >> 4) << 8 | Int(rgba[index * 4 + 1] >> 4) << 4 | Int(rgba[index * 4 + 2] >> 4)
    }

    private static func linear(_ channel: Double) -> Double {
        let value = channel / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
