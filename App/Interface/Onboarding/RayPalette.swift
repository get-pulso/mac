import AppKit

/// Amethyst, the single accepted Ray treatment. RGB values are linear radiance.
enum RayPalette {
    static let amethyst = RayPaletteUniforms(
        low: [0.11, 0.035, 0.36, 0], middle: [0.46, 0.20, 0.80, 0],
        high: [0.86, 0.71, 1, 0], core: [0.94, 0.85, 1, 0],
        surface: [0.021, 0.017, 0.032, 0.68], finish: [0.035, 0.030, 0.090, 1]
    )
}

/// Mirrors the Metal struct: six float4 slots, 96 bytes.
struct RayPaletteUniforms {
    var low: SIMD4<Float>
    var middle: SIMD4<Float>
    var high: SIMD4<Float>
    var core: SIMD4<Float>
    // Legacy palette ABI slots. The compositor uses RaySurface's native window
    // color and one global opacity, not a per-palette exposure mask.
    var surface: SIMD4<Float>
    var finish: SIMD4<Float>
}

/// Display-space native background; shared by the carrier and the native crop.
/// Resolving once per appearance avoids an AppKit color lookup on every frame.
enum RaySurface {
    // MARK: Internal

    static func uniforms(dark: Bool) -> SIMD4<Float> { dark ? Self.dark : self.light }

    static func effectOpacity(at time: Float, dark: Bool) -> Float {
        let start: Float = 1.70, end: Float = 2.20
        let x = min(1, max(0, (time - start) / (end - start)))
        let progress = x * x * x * (x * (x * 6 - 15) + 10)
        return 1 + (self.uniforms(dark: dark).w - 1) * progress
    }

    // MARK: Private

    private static let light = resolve(dark: false)
    private static let dark = resolve(dark: true)

    private static func resolve(dark: Bool) -> SIMD4<Float> {
        var value = SIMD4<Float>(repeating: dark ? 0.15 : 0.93)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            if let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                value = SIMD4(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent), 1)
            }
        }
        value.w = dark ? 0.18 : 0.20
        return value
    }
}
