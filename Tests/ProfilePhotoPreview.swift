import AppKit
import Nuke
import SwiftUI

/// Renders the real photo screen off screen, with a portrait put straight into
/// the image cache so nothing is fetched, and measures what it drew: the
/// picture is opaque and the screen around it is not, so the rect it occupies
/// can be read off the alpha channel. No window is shown, nothing is fetched
/// and no account is touched. Pass a directory to write the frame into.
@main
struct ProfilePhotoPreview {
    @MainActor static func main() {
        _ = NSApplication.shared
        let output = CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory()

        let box = ProfilePhotoLayout.popoverBox
        var checks = 0
        for (label, size) in [("portrait", CGSize(width: 900, height: 1200)),
                              ("square", CGSize(width: 1000, height: 1000)),
                              ("landscape", CGSize(width: 1600, height: 900))] {
            let raw = "https://example.com/\(label).jpg"
            guard let url = URL(string: raw) else { fatalError("No URL") }
            let image = self.portrait(width: Int(size.width), height: Int(size.height))
            // The thumbnail a row would already have drawn. The screen asks the
            // CDN for a larger copy; with nothing answering, this is what it
            // shows, which is the same view at the same size.
            ImagePipeline.shared.cache[url] = ImageContainer(image: image)

            let host = NSHostingView(rootView: ProfilePhotoScreen(url: raw, name: "Ada"))
            host.frame = NSRect(x: 0, y: 0, width: box.width, height: box.height)
            host.layoutSubtreeIfNeeded()

            // The same room whatever shape the photograph is: the panel is the
            // height it was on the profile, and opening a picture does not move
            // the window.
            let fitting = host.fittingSize
            precondition(
                abs(fitting.width - box.width) < 1 && abs(fitting.height - box.height) < 1,
                "\(label): the screen asked for \(fitting), not the \(box.size) every screen here has"
            )

            guard
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
            else { fatalError("No frame") }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(output)/profile-photo-\(label).png"))
            }

            guard let drawn = self.pictureBox(in: rep) else { fatalError("The screen drew no picture for \(label)") }
            guard let wanted = ProfilePhotoLayout.targetRect(
                imageSize: size, in: box, inset: 0, maxScale: 3, pixelScale: 2
            ) else { fatalError("No target rect") }

            precondition(
                abs(drawn.width - wanted.width) <= 2 && abs(drawn.height - wanted.height) <= 2,
                "\(label): the screen drew \(self.short(drawn)), not \(self.short(wanted))"
            )
            // Its own proportions, and inside the room a screen has.
            precondition(
                abs(drawn.width / drawn.height - size.width / size.height) < 0.02,
                "\(label): the picture was stretched: \(self.short(drawn))"
            )
            precondition(
                drawn.width <= box.width + 1 && drawn.height <= box.height + 1,
                "\(label): the picture is larger than the screen holding it: \(self.short(drawn))"
            )
            precondition(
                abs(drawn.midX - box.midX) <= 2 && abs(drawn.midY - box.midY) <= 2,
                "\(label): the picture is not centred: \(self.short(drawn))"
            )
            print("\(label): \(self.short(drawn)) in \(self.short(box))")
            checks += 4
        }

        print("""
        Profile photo preview passed \(checks) checks: the real screen, rendered off screen, draws a portrait, \
        a square and a landscape photograph at their own proportions, centred, in the same \
        \(Int(box.width))x\(Int(box.height)) every screen here takes. Frames in \(output).
        """)
        exit(0)
    }

    // MARK: Private

    /// Where the picture is. It is the only opaque thing the screen draws.
    private static func pictureBox(in rep: NSBitmapImageRep) -> CGRect? {
        guard let data = rep.bitmapData, rep.samplesPerPixel == 4 else { return nil }
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            let row = data + y * rep.bytesPerRow
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (row + x * 4 + 3).pointee > 240 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 2) / scale,
            height: CGFloat(maxY - minY + 2) / scale
        )
    }

    private static func short(_ rect: CGRect) -> String {
        "\(Int(rect.width))x\(Int(rect.height))@\(Int(rect.minX)),\(Int(rect.minY))"
    }

    /// Something with a shape to it, so a crop, a stretch or a wrong centre is
    /// visible rather than a matter of opinion: a circle that has to stay a
    /// circle and a grid that has to stay square.
    private static func portrait(width: Int, height: Int) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [
            NSColor(calibratedRed: 0.26, green: 0.31, blue: 0.44, alpha: 1),
            NSColor(calibratedRed: 0.78, green: 0.62, blue: 0.48, alpha: 1),
        ])?.draw(in: NSRect(origin: .zero, size: size), angle: 78)

        NSColor.white.withAlphaComponent(0.22).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 2
        for x in stride(from: 0, through: CGFloat(width), by: 100) {
            grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: CGFloat(height)))
        }
        for y in stride(from: 0, through: CGFloat(height), by: 100) {
            grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: CGFloat(width), y: y))
        }
        grid.stroke()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let side = CGFloat(min(width, height)) * 0.6
        let circle = NSBezierPath(ovalIn: NSRect(
            x: (CGFloat(width) - side) / 2,
            y: (CGFloat(height) - side) / 2,
            width: side,
            height: side
        ))
        circle.lineWidth = 8
        circle.stroke()
        for (text, y) in [("TOP", CGFloat(height) - 90), ("BOTTOM", 40)] {
            (text as NSString).draw(
                at: NSPoint(x: 40, y: y),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 46, weight: .bold),
                    .foregroundColor: NSColor.white,
                ]
            )
        }
        image.unlockFocus()
        return image
    }
}
