import AppKit
import ImageIO
import Metal

/// Mirrors the Metal struct: five float4 slots, 80 bytes.
struct RayLogoUniforms {
    var frame: SIMD4<Float>
    var crop: SIMD4<Float>
    var options: SIMD4<Float>
    var timing: SIMD4<Float>
    /// Direction, brightness, diagnostic lamp-turn override (-1 live), collection end.
    var ending: SIMD4<Float>
}

/// Shader seconds. The whole living field condenses into the mark between
/// `start` and `gatherEnd`; original pigment replaces it by `end`.
enum RayLogoTiming {
    static let start = 2.05
    static let gatherEnd = 3.15
    static let pigmentStart = 3.17
    static let end = 3.60
    static let side: CGFloat = 92
    /// Screen azimuth of the mark's fan. Must equal `logoMarkAzimuth` in Waves.metal.
    static let direction = 45.0
    /// Opacity of the collected light over the window surface, before pigment.
    static let brightness = 0.50
    /// Collection start, pigment end, pigment start, pigment start: the Soft finish.
    static let soft = SIMD4<Float>(2.05, 3.60, 3.17, 3.17)

    /// The fixed 92 pt slot above Welcome. Both hosts derive it from the panel
    /// size, so the proxy and the native window agree on the optical root.
    static func rect(in panel: CGSize) -> CGRect {
        CGRect(
            x: (panel.width - self.side) / 2,
            y: panel.height * 0.34 - self.side / 2,
            width: self.side,
            height: self.side
        )
    }
}

/// The original AppIcon, bundled by reference. No derived raster is saved.
/// Its black plate is not part of the luminous mark being gathered.
final class RayLogoAsset {
    // MARK: Lifecycle

    init(device: MTLDevice) throws {
        guard let url = Bundle.main.url(forResource: "icon-1024", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ShaderError.missingSource
        }
        self.side = image.width
        guard image.width == image.height else { throw ShaderError.renderFailed }
        let size = image.width
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ShaderError.renderFailed }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        self.rgba = pixels
        var minX = size, minY = size, maxX = 0, maxY = 0
        for y in 0 ..< size {
            for x in 0 ..< size {
                let i = (y * size + x) * 4
                if max(pixels[i], max(pixels[i + 1], pixels[i + 2])) > 18 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX, maxY > minY else { throw ShaderError.renderFailed }
        self.crop = SIMD4(
            Float(minX) / Float(size), Float(minY) / Float(size),
            Float(maxX - minX + 1) / Float(size), Float(maxY - minY + 1) / Float(size)
        )
        // Mip levels let the silhouette emerge from soft lobes of light before
        // it is crisp. Level 0 is the untouched original; pigment reads only it.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: true
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let color = device.makeTexture(descriptor: descriptor) else { throw ShaderError.renderFailed }
        pixels.withUnsafeBytes {
            color.replace(
                region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: size * 4
            )
        }
        guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { throw ShaderError.renderFailed }
        blit.generateMipmaps(for: color)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        self.color = color
        color.label = "Original Firstlight AppIcon · sRGB samples"
    }

    // MARK: Internal

    let color: MTLTexture
    let crop: SIMD4<Float>
    let rgba: [UInt8]
    let side: Int

    func uniforms(state: ShaderState) -> RayLogoUniforms {
        let rect = state.rayLogoRect.isEmpty ? RayLogoTiming.rect(in: state.targetSize) : state.rayLogoRect
        return RayLogoUniforms(
            frame: SIMD4(
                Float(rect.midX - state.targetSize.width / 2), Float(rect.midY - state.targetSize.height / 2),
                Float(rect.width), Float(rect.height)
            ),
            crop: self.crop,
            options: SIMD4(1, state.rayLogoClipOverride, 0, Float(RayLogoTiming.end)),
            timing: RayLogoTiming.soft,
            ending: SIMD4(
                Float(RayLogoTiming.direction * .pi / 180), Float(RayLogoTiming.brightness),
                state.rayLampTurnOverride, Float(RayLogoTiming.gatherEnd)
            )
        )
    }
}
