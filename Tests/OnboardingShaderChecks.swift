import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers

enum OnboardingShaderChecks {
    // MARK: Internal

    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ShaderError.unavailable }
        let renderer = try MetalRenderer(device: device)
        let folder = URL(fileURLWithPath: "/tmp/pulso-integrated-gas-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let times: [Float] = [0, 0.7, 1.8, 2.8, 3.55, 3.72, 3.95, 4.1, 4.6, 5.8]
        var slowestGPU = 0.0
        var measuredGPU: [Double] = []
        var previews: [CGImage] = []
        for variant in [2] {
            for size in [CGSize(width: 1020, height: 760), CGSize(width: 820, height: 620)] {
                for scale in [1, 2] {
                    var earlyPixels: [UInt8]?
                    for time in times {
                        let width = Int(size.width) * scale, height = Int(size.height) * scale
                        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
                        )
                        textureDescriptor.usage = [.renderTarget]
                        textureDescriptor.storageMode = .shared
                        guard let texture = device.makeTexture(descriptor: textureDescriptor),
                              let command = renderer.commandQueue.makeCommandBuffer()
                        else { throw ShaderError.renderFailed }
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture = texture
                        pass.colorAttachments[0].loadAction = .clear
                        pass.colorAttachments[0].storeAction = .store
                        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                        renderer.state = ShaderState(elapsed: time, inset: 76, nativeSurface: false, variant: variant)
                        renderer.encode(pass: pass, command: command, width: width, height: height, scale: Float(scale))
                        command.commit()
                        command.waitUntilCompleted()
                        guard command.status == .completed else { throw command.error ?? ShaderError.renderFailed }
                        let gpuMS = (command.gpuEndTime - command.gpuStartTime) * 1000
                        slowestGPU = max(slowestGPU, gpuMS)
                        if time >= 1.8 { measuredGPU.append(gpuMS) }
                        var bytes = [UInt8](repeating: 0, count: width * height * 4)
                        bytes.withUnsafeMutableBytes {
                            texture.getBytes(
                                $0.baseAddress!,
                                bytesPerRow: width * 4,
                                from: MTLRegionMake2D(0, 0, width, height),
                                mipmapLevel: 0
                            )
                        }
                        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
                        var visible = 0
                        var maxAlpha: UInt8 = 0
                        var edgePixels = 0
                        for y in 0 ..< height {
                            for x in 0 ..< width {
                                let index = (y * width + x) * 4, a = bytes[index + 3]
                                if a > 0 { visible += 1 }
                                if a > 10, a < 180 { edgePixels += 1 }
                                maxAlpha = max(maxAlpha, a)
                                for channel in 0 ..< 3 where Int(bytes[index + channel]) > Int(a) + 1 {
                                    throw ShaderError.invalidPixels("Non-premultiplied color at t=\(time)")
                                }
                            }
                        }
                        guard alpha(0, 0) == 0, alpha(width - 1, height - 1) == 0 else {
                            throw ShaderError.invalidPixels("Carrier corners are not clear")
                        }
                        if time == 0, visible != 0 { throw ShaderError.invalidPixels("First frame is not clear") }
                        if time > 1, time < 3.6 {
                            guard visible > 20000 * scale * scale, maxAlpha < 245, edgePixels > 6000 * scale * scale,
                                  alpha(100 * scale, height / 2) == 0
                            else {
                                throw ShaderError
                                    .invalidPixels("Missing translucent gas / unexpected window before morph")
                            }
                        }
                        if time == 1.8 { earlyPixels = bytes }
                        if time == 2.8, let earlyPixels {
                            let changed = zip(bytes, earlyPixels).filter { abs(Int($0) - Int($1)) > 4 }.count
                            guard changed > 10000 * scale * scale
                            else { throw ShaderError.invalidPixels("Gas does not flow") }
                        }
                        if time > 5 {
                            guard alpha(width / 2, height / 2) == 255, alpha(90 * scale, height / 2) == 255 else {
                                throw ShaderError.invalidPixels("Missing final window")
                            }
                        }
                        if size.width == 1020, scale == 1 {
                            let image = try makeImage(bytes, width: width, height: height)
                            let name = "opal"
                            try save(image, to: folder.appendingPathComponent("\(name)-\(time).png"))
                            if time == 2.8 || time == 3.95 || time == 5.8 {
                                let preview = try composite(image, dim: IntroTiming.dimming(at: Double(time)))
                                previews.append(preview)
                                try self.save(preview, to: folder.appendingPathComponent("\(name)-\(time)-preview.png"))
                            }
                        }
                        if time == 5.8 {
                            guard let nativeCommand = renderer.commandQueue.makeCommandBuffer() else {
                                throw ShaderError.renderFailed
                            }
                            renderer.state = ShaderState(elapsed: time, inset: 0, nativeSurface: true, variant: variant)
                            renderer.encode(
                                pass: pass,
                                command: nativeCommand,
                                width: width,
                                height: height,
                                scale: Float(scale)
                            )
                            nativeCommand.commit()
                            nativeCommand.waitUntilCompleted()
                            guard nativeCommand.status == .completed else { throw ShaderError.renderFailed }
                            var corner = [UInt8](repeating: 0, count: 4)
                            for point in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
                                corner.withUnsafeMutableBytes {
                                    texture.getBytes(
                                        $0.baseAddress!,
                                        bytesPerRow: 4,
                                        from: MTLRegionMake2D(point.0, point.1, 1, 1),
                                        mipmapLevel: 0
                                    )
                                }
                                guard corner[3] == 255 else {
                                    throw ShaderError.invalidPixels("Shader is rounding a native window corner")
                                }
                            }
                            print("PASS: native surface is unmasked; AppKit exclusively clips corners @\(scale)x")
                        }
                        print(
                            "PASS \("Opal") \(Int(size.width))x\(Int(size.height)) @\(scale)x t=\(time) alpha=\(maxAlpha) gpu=\(String(format: "%.2f", gpuMS))ms"
                        )
                    }
                }
            }
        }
        guard IntroTiming.dimming(at: 0) == 0,
              IntroTiming.dimming(at: 2) > 0.7,
              IntroTiming.dimming(at: 4.5) < IntroTiming.dimming(at: 3.7),
              IntroTiming.dimming(at: IntroTiming.duration) == 0
        else {
            throw ShaderError.invalidPixels("Invalid desktop dimming timeline")
        }
        let context = CGContext(
            data: nil,
            width: 1530,
            height: 380,
            bitsPerComponent: 8,
            bytesPerRow: 1530 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for (index, preview) in previews.enumerated() {
            context.draw(preview, in: CGRect(x: index * 510, y: 0, width: 510, height: 380))
        }
        try self.save(context.makeImage()!, to: folder.appendingPathComponent("opal-storyboard.png"))
        let average = measuredGPU.reduce(0,+) / Double(measuredGPU.count)
        print("40 Opal GPU frames passed; dimming, alpha, motion, compact/Retina sizes verified.")
        print(
            "GPU mean \(String(format: "%.2f", average))ms, max \(String(format: "%.2f", slowestGPU))ms. Frames: \(folder.path)"
        )
    }

    // MARK: Private

    private static func makeImage(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let bitmap = CGBitmapInfo.byteOrder32Little
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmap,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { throw ShaderError.renderFailed }
        return image
    }

    private static func composite(_ image: CGImage, dim: Double) throws -> CGImage {
        let width = image.width, height = image.height
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
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
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ShaderError.renderFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShaderError.renderFailed }
    }
}
