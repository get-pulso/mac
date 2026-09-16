import AppKit
import ImageIO

/// The original mark as a plain image, cropped exactly as the shader crops it,
/// so it can take the shader's place once the light has become the mark and
/// then move with the SwiftUI name as one piece, at full Retina resolution.
enum RayLogoImage {
    static let cropped: NSImage? = {
        guard let url = Bundle.main.url(forResource: "icon-1024", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let size = image.width
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        // The same rule the shader applies: the black plate is not the mark.
        // Its pixels become transparent, with the shader's soft edge
        // (smoothstep over 0.012…0.07 of peak brightness) as alpha.
        var minX = size, minY = size, maxX = 0, maxY = 0
        for y in 0 ..< size {
            for x in 0 ..< size {
                let i = (y * size + x) * 4
                let peak = Float(max(pixels[i], max(pixels[i + 1], pixels[i + 2]))) / 255
                if peak > 18.0 / 255 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                let t = min(1, max(0, (peak - 0.012) / (0.07 - 0.012)))
                let mask = t * t * (3 - 2 * t)
                let alpha = Float(pixels[i + 3]) / 255 * mask
                pixels[i] = UInt8(Float(pixels[i]) * mask)
                pixels[i + 1] = UInt8(Float(pixels[i + 1]) * mask)
                pixels[i + 2] = UInt8(Float(pixels[i + 2]) * mask)
                pixels[i + 3] = UInt8(alpha * 255)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let masked: CGImage? = pixels.withUnsafeMutableBytes { bytes in
            CGContext(
                data: bytes.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        guard let crop = masked?
            .cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
    }()
}
