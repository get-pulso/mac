import AppKit
import CoreText
import ImageIO
import SwiftUI

/// What a portrait draws when there is no photograph: the one letter it shows,
/// where that letter sits in its circle, and how a letter tile Google drew is
/// told from a photograph. The pictures are made here — coloured squares with
/// a letter, and pictures that only resemble one — and go through JPEG the way
/// Google's do. No network, no accounts, no windows.
@main
struct AvatarPlaceholderChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        checks += self.checkLetter()
        checks += self.checkCentring()
        checks += self.checkTiles()
        checks += self.checkLookalikes()
        checks += self.checkSources()
        print("""
        Avatar placeholder checks passed: \(checks); \
        the first letter of a name through punctuation, emoji, accents, scripts and letters with no \
        one-letter capital, the letter's ink centred in its circle, Google's letter \
        squares in eight grounds and three scripts after JPEG, and photographs that only resemble one — plain \
        backdrops, black and white, a night sky, grey, pale, a second colour, mostly white and a cut-out — plus \
        which addresses are looked into at all and what is remembered of them.
        """)
    }

    // MARK: Private

    /// The letter drawn by the real view, off screen at Retina scale, and its
    /// ink measured. Large, so that the half point a letter can be snapped by
    /// is small beside what is being checked: centred by its line instead, a
    /// capital here sits nine or ten pixels low, a D leans four to the right
    /// and a Я three to the left.
    @MainActor private static func checkCentring() -> Int {
        let diameter: CGFloat = 400
        let letters = ["D", "S", "A", "Я", "4", "W"]
        for letter in letters {
            let host = NSHostingView(rootView: ZStack {
                Color.white
                AvatarLetter(letter: letter, size: diameter * 0.44).foregroundStyle(.black)
            }
            .frame(width: diameter, height: diameter)
            .environment(\.displayScale, 2))
            host.frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)
            host.layoutSubtreeIfNeeded()
            guard
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds),
                rep.bitsPerSample == 8
            else { preconditionFailure("No bitmap to draw \(letter) into") }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.bitmapData else { preconditionFailure("No pixels for \(letter)") }

            // The first colour channel of each pixel: dark where the ink is.
            let channel = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
            let step = rep.bitsPerPixel / 8
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            for y in 0 ..< rep.pixelsHigh {
                for x in 0 ..< rep.pixelsWide where data[y * rep.bytesPerRow + x * step + channel] < 128 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            precondition(maxX >= minX, "\(letter) drew nothing")
            let across = Double(minX + maxX + 1) / 2 - Double(rep.pixelsWide) / 2
            let down = Double(minY + maxY + 1) / 2 - Double(rep.pixelsHigh) / 2
            precondition(
                abs(across) <= 1.5 && abs(down) <= 1.5,
                "\(letter) is off centre by \(across), \(down) px"
            )
        }
        return letters.count
    }

    private static func checkLetter() -> Int {
        let cases: [(String, String?)] = [
            ("Sam", "S"),
            ("  anna", "A"),
            ("@serafim", "S"),
            ("🙂 Anna", "A"),
            ("élodie", "É"),
            ("e\u{301}lodie", "E\u{301}"),
            ("ярослав", "Я"),
            ("山田", "山"),
            ("42nd", "4"),
            // No capital that is still one letter: the letter stays as it is.
            ("ßeta", "ß"),
            ("ﬁona", "ﬁ"),
            ("", nil),
            ("🙂", nil),
            ("...", nil),
        ]
        for (name, wanted) in cases {
            let letter = AvatarMonogram.letter(for: name)
            precondition(letter == wanted, "\(name.debugDescription) gave \(String(describing: letter)), not \(String(describing: wanted))")
            precondition(letter.map { $0.count == 1 } ?? true, "\(name.debugDescription) gave more than one letter")
        }
        return cases.count * 2
    }

    /// Grounds Google has been seen to use, light and dark, and letters from
    /// three scripts, lower case among them.
    private static func checkTiles() -> Int {
        let grounds: [(CGFloat, CGFloat, CGFloat)] = [
            (0x00, 0x89, 0x7B), (0x7E, 0x57, 0xC2), (0x5C, 0x6B, 0xC0), (0xEC, 0x40, 0x7A),
            (0x46, 0x5A, 0x65), (0xF4, 0x51, 0x1E), (0x00, 0x4D, 0x40), (0x8D, 0x6E, 0x63),
        ]
        var checks = 0
        for (index, ground) in grounds.enumerated() {
            let letter = ["A", "d", "Я"][index % 3]
            let tile = self.jpeg(self.picture { context, side in
                context.setFillColor(self.color(ground))
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                self.letter(letter, in: context, side: side, color: CGColor(gray: 1, alpha: 1))
            })
            precondition(AvatarTile.isLetter(tile), "Google's \(letter) on \(ground) was taken for a photograph")
            checks += 1
        }
        return checks
    }

    private static func checkLookalikes() -> Int {
        var random = Random(seed: 7)
        let lookalikes: [(String, CGImage)] = [
            // A face-coloured subject with shading, in front of a plain coloured
            // backdrop that covers most of the picture.
            ("a subject in front of a plain backdrop", self.jpeg(self.picture { context, side in
                context.setFillColor(self.color((0x3F, 0x6F, 0xB5)))
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for step in 0 ..< 40 {
                    let shade = CGFloat(step) / 40
                    context.setFillColor(self.color((0xE0 - 90 * shade, 0xAC - 70 * shade, 0x90 - 60 * shade)))
                    let inset = side * 0.3 + CGFloat(step) * 1.5
                    context.fillEllipse(in: CGRect(x: inset, y: side * 0.05 + CGFloat(step), width: side - 2 * inset, height: side * 0.5))
                }
            })),
            // Black and white against black: every pixel lies between the
            // ground and white, and only the ground being black gives it away.
            ("black and white against black", self.jpeg(self.picture { context, side in
                context.setFillColor(CGColor(gray: 0.03, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for _ in 0 ..< 60 {
                    context.setFillColor(CGColor(gray: random.next(in: 0.3 ... 1), alpha: 1))
                    context.fillEllipse(in: CGRect(x: side * 0.35 + random.next(in: 0 ... side * 0.2), y: side * 0.3 + random.next(in: 0 ... side * 0.2), width: 14, height: 14))
                }
            })),
            // Something light against a night sky: a colour, but too dark to be
            // a ground anyone would put white type on.
            ("something light against a night sky", self.jpeg(self.picture { context, side in
                context.setFillColor(self.color((10, 10, 48)))
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for _ in 0 ..< 40 {
                    context.setFillColor(CGColor(gray: 1, alpha: random.next(in: 0.2 ... 1)))
                    context.fillEllipse(in: CGRect(x: side * 0.35 + random.next(in: 0 ... side * 0.2), y: side * 0.35 + random.next(in: 0 ... side * 0.2), width: 10, height: 10))
                }
            })),
            // A white letter, but on grey rather than a colour.
            ("a letter on grey", self.jpeg(self.picture { context, side in
                context.setFillColor(CGColor(gray: 0.45, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                self.letter("M", in: context, side: side, color: CGColor(gray: 1, alpha: 1))
            })),
            // Too pale a ground to hold white type.
            ("a letter on a pale ground", self.jpeg(self.picture { context, side in
                context.setFillColor(self.color((0xFF, 0xEC, 0xB2)))
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                self.letter("M", in: context, side: side, color: CGColor(gray: 1, alpha: 1))
            })),
            // A coloured square with a letter and a second colour in it.
            ("a logo with a second colour", self.jpeg(self.picture { context, side in
                context.setFillColor(self.color((0x5C, 0x6B, 0xC0)))
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                context.setFillColor(self.color((0xF9, 0xA8, 0x25)))
                context.fillEllipse(in: CGRect(x: side * 0.55, y: side * 0.55, width: side * 0.35, height: side * 0.35))
                self.letter("M", in: context, side: side, color: CGColor(gray: 1, alpha: 1))
            })),
            // Two colours only, as in a letter, but the white is most of it.
            ("a large white shape on a colour", self.jpeg(self.picture { context, side in
                context.setFillColor(self.color((0x00, 0x89, 0x7B)))
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.6))
            })),
            // The letter on a round ground with nothing around it.
            ("a cut-out on a clear ground", self.picture { context, side in
                context.setFillColor(self.color((0x7E, 0x57, 0xC2)))
                context.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
                self.letter("A", in: context, side: side, color: CGColor(gray: 1, alpha: 1))
            }),
            // Grain everywhere, the way a photograph has it.
            ("noise", self.jpeg(self.picture { context, side in
                for y in stride(from: CGFloat(0), to: side, by: 8) {
                    for x in stride(from: CGFloat(0), to: side, by: 8) {
                        context.setFillColor(self.color((random.next(in: 0 ... 255), random.next(in: 0 ... 255), random.next(in: 0 ... 255))))
                        context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                    }
                }
            })),
        ]
        for (label, image) in lookalikes {
            precondition(!AvatarTile.isLetter(image), "\(label) was taken for Google's letter")
        }
        // Nothing at all to read.
        precondition(!AvatarTile.isLetter(rgba: []), "No pixels were taken for a letter")
        return lookalikes.count + 1
    }

    /// Only a picture Google supplied is looked into, and the answer is kept
    /// under its address; Clerk's tile needs no picture at all.
    private static func checkSources() -> Int {
        let tile = self.jpeg(self.picture { context, side in
            context.setFillColor(self.color((0x00, 0x89, 0x7B)))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            self.letter("A", in: context, side: side, color: CGColor(gray: 1, alpha: 1))
        })
        let image = NSImage(cgImage: tile, size: NSSize(width: tile.width, height: tile.height))

        let google = "https://img.clerk.com/\(self.token(#"{"type":"proxy","src":"https://images.clerk.dev/oauth_google/img_checks"}"#))"
        let uploaded = "https://img.clerk.com/\(self.token(#"{"type":"proxy","src":"https://images.clerk.dev/uploaded/img_checks"}"#))"
        let clerk = "https://img.clerk.com/\(self.token(#"{"type":"default","initials":"SK"}"#))"

        precondition(!AvatarTile.isKnownDrawn(google), "A picture nobody has looked at was already known")
        precondition(AvatarTile.isDrawn(google, image: image), "Google's letter was shown as a photograph")
        precondition(AvatarTile.isKnownDrawn(google), "What was seen of Google's letter was not kept")
        // The answer is kept by address, so the picture is not needed again.
        precondition(AvatarTile.isDrawn(google, image: nil), "The kept answer was not used")
        precondition(!AvatarTile.isDrawn(uploaded, image: image), "An upload that looks like a letter was hidden")
        precondition(!AvatarTile.isKnownDrawn(uploaded), "An upload was remembered as a drawn tile")
        precondition(AvatarTile.isDrawn(clerk, image: nil), "Clerk's own tile needed a picture to be recognised")
        precondition(AvatarTile.isKnownDrawn(clerk), "Clerk's own tile was not known from its address")
        precondition(!AvatarTile.isDrawn(nil, image: image), "No address was taken for a drawn tile")
        precondition(!AvatarTile.isDrawn("https://example.com/a.jpg", image: image), "A picture from elsewhere was looked into")
        return 10
    }

    // MARK: Pictures

    private struct Random {
        var state: UInt64

        init(seed: UInt64) { self.state = seed }

        mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
            self.state = self.state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = CGFloat(self.state >> 11) / CGFloat(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }

    /// A square picture the size Google serves, on a clear ground.
    private static func picture(_ draw: (CGContext, CGFloat) -> Void) -> CGImage {
        let side = 400
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { preconditionFailure("No context to draw in") }
        draw(context, CGFloat(side))
        guard let image = context.makeImage() else { preconditionFailure("Nothing drawn") }
        return image
    }

    /// The same picture after a trip through JPEG, grain and soft edges included.
    private static func jpeg(_ image: CGImage) -> CGImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { preconditionFailure("No JPEG encoder") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard
            CGImageDestinationFinalize(destination),
            let source = CGImageSourceCreateWithData(data, nil),
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { preconditionFailure("The JPEG did not come back") }
        return decoded
    }

    private static func letter(_ text: String, in context: CGContext, side: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("Helvetica" as CFString, side * 0.5, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        ))
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: (side - bounds.width) / 2 - bounds.minX, y: (side - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
    }

    private static func color(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGColor {
        CGColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
    }

    /// The payload Clerk signs into the path, as `ProfilePhotoChecks` makes it.
    private static func token(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
