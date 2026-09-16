import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Offscreen GPU checks of the production Ray / Flow onboarding light.
enum OnboardingShaderChecks {
    // MARK: Internal

    static func run() throws {
        guard MemoryLayout<ShaderUniforms>.stride == 64,
              MemoryLayout<RayPaletteUniforms>.stride == 96,
              MemoryLayout<RayLogoUniforms>.stride == 96
        else { throw ShaderError.invalidPixels("Swift/Metal uniform layout mismatch") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw ShaderError.unavailable }
        let renderer = try MetalRenderer(device: device)
        let folder = URL(fileURLWithPath: "/tmp/firstlight-integrated-ray-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let times: [Float] = [0, 0.35, 0.65, 1.10, 1.75, 2.05, 2.35, 2.65, 2.95, 3.15, 3.60, 4.0]
        var count = 0
        var gpu: [Double] = []
        var previews: [CGImage] = []
        for size in [CGSize(width: 1020, height: 760), CGSize(width: 820, height: 620)] {
            let panel = CGSize(width: size.width - 152, height: size.height - 152)
            for scale in [1, 2] {
                var early: Frame?
                for time in times {
                    let state = ShaderState(elapsed: time, inset: 76, nativeSurface: false, variant: 2, targetSize: panel)
                    let frame = try render(renderer, size: size, scale: scale, state: state)
                    count += 1
                    if time >= 1.10 { gpu.append(frame.gpuMS) }
                    try validate(frame, time: time, scale: scale)
                    if time == 0.65 { early = frame }
                    if time == 1.10, let early {
                        guard changed(frame, early) > 500 * scale * scale else {
                            throw ShaderError.invalidPixels("Light does not move")
                        }
                    }
                    if time >= Float(IntroTiming.handoff) {
                        // From the handoff on, the native window shows the same pixels.
                        var nativeState = state
                        nativeState.inset = 0
                        nativeState.nativeSurface = true
                        let native = try render(renderer, size: panel, scale: scale, state: nativeState)
                        count += 1
                        for point in [(0, 0), (native.width - 1, 0), (0, native.height - 1),
                                      (native.width - 1, native.height - 1)]
                        {
                            guard native.alpha(point.0, point.1) == 255 else {
                                throw ShaderError.invalidPixels("Shader is rounding a native window corner")
                            }
                        }
                        for y in stride(from: 16 * scale, to: native.height - 16 * scale, by: 17) {
                            for x in stride(from: 16 * scale, to: native.width - 16 * scale, by: 17) {
                                for c in 0 ..< 4 {
                                    guard abs(Int(frame.channel(x + 76 * scale, y + 76 * scale, c)) -
                                        Int(native.channel(x, y, c))) <= 1
                                    else { throw ShaderError.invalidPixels("Native handoff mismatch at \(time)") }
                                }
                            }
                        }
                    }
                    if time == Float(IntroTiming.logoSettled) {
                        // The original mark: identical whatever the seed or later time,
                        // and already in place at the end of pigment.
                        var pigmented = state
                        pigmented.elapsed = Float(RayLogoTiming.pigmentEnd)
                        let early = try render(renderer, size: size, scale: scale, state: pigmented)
                        count += 1
                        guard early.bytes == frame.bytes else {
                            throw ShaderError.invalidPixels("The mark is not final at \(RayLogoTiming.pigmentEnd) s")
                        }
                        var later = state
                        later.elapsed = 42
                        later.variant = 9901
                        let final = try render(renderer, size: size, scale: scale, state: later)
                        count += 1
                        guard final.bytes == frame.bytes else {
                            throw ShaderError.invalidPixels("Final logo depends on shader time or seed")
                        }
                        let slot = RayLogoTiming.rect(in: panel)
                        var mark = 0
                        let surface = RaySurface.uniforms(dark: true)
                        for y in stride(from: 12, to: Int(panel.height) - 12, by: 7) {
                            for x in stride(from: 12, to: Int(panel.width) - 12, by: 7) {
                                let differences = (0 ..< 3).map {
                                    abs(Float(frame.channel((x + 76) * scale, (y + 76) * scale, $0)) - surface[2 - $0] * 255)
                                }
                                if !slot.insetBy(dx: -2, dy: -2).contains(CGPoint(x: x, y: y)) {
                                    guard differences.max()! <= 2 else {
                                        throw ShaderError.invalidPixels("Light remains outside the mark at \(x),\(y)")
                                    }
                                } else if differences.max()! > 25 { mark += 1 }
                            }
                        }
                        guard mark > 20 else { throw ShaderError.invalidPixels("Firstlight mark is missing") }
                        // Once the mark has left, only the plain window surface remains.
                        var gone = state
                        gone.rayLogoExit = 1
                        let empty = try render(renderer, size: size, scale: scale, state: gone)
                        count += 1
                        for y in stride(from: 12, to: Int(panel.height) - 12, by: 5) {
                            for x in stride(from: 12, to: Int(panel.width) - 12, by: 5) {
                                for c in 0 ..< 3 {
                                    guard abs(Float(empty.channel((x + 76) * scale, (y + 76) * scale, c)) - surface[2 - c] * 255) <= 2
                                    else { throw ShaderError.invalidPixels("The mark's exit leaves light behind at \(x),\(y)") }
                                }
                            }
                        }
                        var leaving = state
                        leaving.rayLogoExit = 0.5
                        let half = try render(renderer, size: size, scale: scale, state: leaving)
                        count += 1
                        guard changed(half, frame) > 40, changed(half, empty) > 40 else {
                            throw ShaderError.invalidPixels("The mark's exit is not gradual")
                        }
                    }
                    if size.width == 1020, scale == 1 {
                        let image = try makeImage(frame)
                        try save(image, to: folder.appendingPathComponent("ray-\(time).png"))
                        if [1.10, 2.35, 2.95, 3.60].contains(time) {
                            let preview = try composite(image, dim: 0)
                            previews.append(preview)
                        }
                    }
                }
            }
        }
        // Dense 60 Hz continuity through the turn, condensation and pigment.
        var previous: Frame?
        var maximumDelta = 0.0
        for step in 0 ... 240 {
            let time = Float(step) / 60
            let frame = try render(
                renderer, size: CGSize(width: 510, height: 380), scale: 1,
                state: ShaderState(elapsed: time, inset: 38, variant: 703, targetSize: CGSize(width: 434, height: 304))
            )
            count += 1
            if let previous {
                let delta = zip(previous.bytes, frame.bytes).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
                    / Double(frame.bytes.count) / 255
                maximumDelta = max(maximumDelta, delta)
            }
            previous = frame
        }
        guard maximumDelta < 0.045 else { throw ShaderError.invalidPixels("Frame discontinuity: \(maximumDelta)") }
        guard IntroTiming.dimming(atReal: 0) == 0,
              abs(IntroTiming.dimming(atReal: 1.5) - IntroTiming.dimmingPeak) < 0.001,
              IntroTiming.dimming(atReal: IntroTiming.realHandoff) == 0,
              IntroTiming.dimming(atReal: IntroTiming.realDuration) == 0
        else {
            throw ShaderError.invalidPixels("Invalid desktop dimming timeline")
        }
        let context = CGContext(
            data: nil, width: 2040, height: 380, bitsPerComponent: 8, bytesPerRow: 2040 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for (index, preview) in previews.enumerated() {
            context.draw(preview, in: CGRect(x: index * 510, y: 0, width: 510, height: 380))
        }
        try self.save(context.makeImage()!, to: folder.appendingPathComponent("ray-storyboard.png"))
        let average = gpu.reduce(0,+) / Double(gpu.count)
        print(
            "\(count) Ray GPU frames passed: premultiplied alpha, clear carrier edges, motion, native handoff match from \(IntroTiming.handoff) s, static original mark, 60 Hz delta ≤\(String(format: "%.4f", maximumDelta)), dimming timeline."
        )
        print("GPU mean \(String(format: "%.2f", average))ms, max \(String(format: "%.2f", gpu.max() ?? 0))ms. Frames: \(folder.path)")
    }

    // MARK: Private

    private struct Frame {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        let gpuMS: Double
        func channel(_ x: Int, _ y: Int, _ c: Int) -> UInt8 { self.bytes[(y * self.width + x) * 4 + c] }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { self.channel(x, y, 3) }
    }

    private static func render(_ renderer: MetalRenderer, size: CGSize, scale: Int, state: ShaderState) throws -> Frame {
        let width = Int(size.width) * scale, height = Int(size.height) * scale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = renderer.commandQueue.device.makeTexture(descriptor: descriptor),
              let command = renderer.commandQueue.makeCommandBuffer() else { throw ShaderError.renderFailed }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        renderer.state = state
        try renderer.encode(pass: pass, command: command, width: width, height: height, scale: Float(scale))
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? ShaderError.renderFailed }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return Frame(width: width, height: height, bytes: bytes, gpuMS: (command.gpuEndTime - command.gpuStartTime) * 1000)
    }

    private static func validate(_ frame: Frame, time: Float, scale: Int) throws {
        var visible = 0, soft = 0, maxAlpha: UInt8 = 0
        for index in stride(from: 0, to: frame.bytes.count, by: 4) {
            let a = frame.bytes[index + 3]
            if a > 0 { visible += 1 }
            if a > 10, a < 180 { soft += 1 }
            maxAlpha = max(maxAlpha, a)
            for c in 0 ..< 3 where Int(frame.bytes[index + c]) > Int(a) + 1 {
                throw ShaderError.invalidPixels("Non-premultiplied pixel at \(time)")
            }
        }
        for x in stride(from: 0, to: frame.width, by: 13) {
            guard frame.alpha(x, 0) == 0, frame.alpha(x, frame.height - 1) == 0 else {
                throw ShaderError.invalidPixels("Carrier top/bottom clipping at \(time)")
            }
        }
        for y in stride(from: 0, to: frame.height, by: 13) {
            guard frame.alpha(0, y) == 0, frame.alpha(frame.width - 1, y) == 0 else {
                throw ShaderError.invalidPixels("Carrier side clipping at \(time)")
            }
        }
        if time == 0, visible != 0 { throw ShaderError.invalidPixels("First frame is not clear") }
        if time > 0.5, time < 1.05 {
            guard visible > 3000 * scale * scale, maxAlpha < 245, soft > 1000 * scale * scale else {
                throw ShaderError.invalidPixels("Missing translucent light at \(time)")
            }
        }
        if time >= Float(IntroTiming.handoff) {
            guard frame.alpha(frame.width / 2, frame.height / 2) == 255,
                  frame.alpha(90 * scale, frame.height / 2) == 255
            else { throw ShaderError.invalidPixels("Missing window surface at \(time)") }
        }
    }

    private static func changed(_ a: Frame, _ b: Frame) -> Int {
        zip(a.bytes, b.bytes).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 2 ? 1 : 0) }
    }

    private static func makeImage(_ frame: Frame) throws -> CGImage {
        let provider = CGDataProvider(data: Data(frame.bytes) as CFData)!
        let bitmap = CGBitmapInfo.byteOrder32Little
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let image = CGImage(
            width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmap, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { throw ShaderError.renderFailed }
        return image
    }

    private static func composite(_ image: CGImage, dim: Double) throws -> CGImage {
        let width = image.width, height = image.height
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Synthetic desktop for reproducible alpha proof, not a screenshot of user data.
        context.setFillColor(CGColor(red: 0.46, green: 0.43, blue: 0.42, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: dim))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ShaderError.renderFailed }
        return result
    }

    private static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ShaderError.renderFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShaderError.renderFailed }
    }
}
