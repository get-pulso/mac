import AppKit

// Renders the DMG window background: black ground, an amethyst halo behind the
// header, the mark beside the name (the onboarding header pair, scaled), and a
// hand-drawn ink arrow between where Finder places the app and Applications.
//
// usage: swift render-background.swift <mark.png> <scale> <out.png>
// The canvas is 660×400 pt; Finder shows it under a window of exactly that size.

let args = CommandLine.arguments
guard args.count == 4, let scale = Int(args[2]), let mark = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: render-background.swift <mark.png> <scale> <out.png>\n".utf8))
    exit(1)
}

let width = 660.0, height = 400.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
context.cgContext.setAllowsFontSmoothing(true)

// Points below are given top-down like the design; flip once here.
func p(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: x, y: height - y) }

NSColor.black.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Halo: the mark's own radiance, spilling from the header down toward the icons.
let amethyst = NSColor(srgbRed: 0xC0 / 255, green: 0x82 / 255, blue: 1, alpha: 1)
let violet = NSColor(srgbRed: 0x8A / 255, green: 0x5C / 255, blue: 0xE0 / 255, alpha: 1)
let cg = context.cgContext
let haloGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [amethyst.withAlphaComponent(0.40).cgColor, violet.withAlphaComponent(0.15).cgColor,
                                       amethyst.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 0.55, 1])!
cg.saveGState()
// An ellipse 840×500 centred on the header: a circle of radius 420 squashed vertically.
cg.translateBy(x: 330, y: height - 32)
cg.scaleBy(x: 1, y: 250 / 420)
cg.drawRadialGradient(haloGradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 420, options: [])
cg.restoreGState()

// Header pair, the onboarding header proportions with a lighter mark:
// mark height 32, gap 8, name 22 pt medium with -0.8 tracking, both centred on y 44.
let nameFont = NSFont.systemFont(ofSize: 22, weight: .medium)
let name = NSAttributedString(string: "Firstlight", attributes: [
    .font: nameFont, .kern: -0.8, .foregroundColor: NSColor.white.withAlphaComponent(0.92),
])
let markHeight = 32.0
let markWidth = markHeight * mark.size.width / mark.size.height
let gap = 8.0
let nameWidth = ceil(name.size().width)
let pairLeft = 330 - (markWidth + gap + nameWidth) / 2
let centerY = 44.0
mark.draw(in: NSRect(x: pairLeft, y: height - (centerY + markHeight / 2), width: markWidth, height: markHeight),
          from: .zero, operation: .sourceOver, fraction: 1)
// Centre the name on its cap height so it sits level with the mark, not with its descenders.
let baseline = centerY + nameFont.capHeight / 2
name.draw(at: NSPoint(x: pairLeft + markWidth + gap, y: height - baseline - nameFont.descender.magnitude))

// Ink arrow: one S stroke and a two-stroke open head, drawn in the pale end of the mark's ramp.
let ink = NSColor(srgbRed: 0xE5 / 255, green: 0xCA / 255, blue: 1, alpha: 0.88)
ink.setStroke()
let stroke = NSBezierPath()
stroke.lineWidth = 2
stroke.lineCapStyle = .round
stroke.lineJoinStyle = .round
stroke.move(to: p(248, 208))
stroke.curve(to: p(344, 168), controlPoint1: p(278, 230), controlPoint2: p(308, 150))
stroke.curve(to: p(408, 194), controlPoint1: p(380, 186), controlPoint2: p(396, 212))
stroke.stroke()
let head = NSBezierPath()
head.lineWidth = 2
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: p(394, 186))
head.curve(to: p(411, 195), controlPoint1: p(402, 189), controlPoint2: p(408, 192))
head.curve(to: p(401, 211), controlPoint1: p(407, 200), controlPoint2: p(403, 205))
head.stroke()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: args[3]))
