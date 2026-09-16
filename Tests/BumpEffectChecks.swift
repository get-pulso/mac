import Foundation
import Metal

@main enum BumpEffectChecks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ reason: String) {
            precondition(condition, reason)
            checks += 1
        }
        for effect in BumpEffect.allCases {
            for step in 0 ... 1000 {
                let time = Double(step) / 1000 * effect.duration
                let m = BumpEffectMotion.sample(effect, at: time, reduced: false)
                expect([m.x, m.y, m.rotation, m.scaleX, m.scaleY, m.cardY].allSatisfy(\.isFinite), "finite motion")
                expect(abs(m.x) <= 7 && abs(m.y) <= 9.5 && abs(m.rotation) <= 4, "bounded motion")
                expect((0.93 ... 1.07).contains(m.scaleX) && (0.93 ... 1.07).contains(m.scaleY), "bounded deformation")
                let still = BumpEffectMotion.sample(effect, at: time, reduced: true)
                expect(still.x == 0 && still.y == 0 && still.rotation == 0 && still.scaleX == 1 && still.scaleY == 1 && still.cardY == 0, "Reduce Motion stays stationary")
            }
            for time in [-1.0, 0, effect.duration, effect.duration + 1, .infinity, .nan] {
                let m = BumpEffectMotion.sample(effect, at: time, reduced: false)
                expect(m.x == 0 && m.y == 0 && m.rotation == 0 && m.scaleX == 1 && m.scaleY == 1 && m.cardY == 0, "idle resets geometry")
            }
        }

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("GPU verification requires a Metal device")
        }
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: "bumpVertex")
        pipeline.fragmentFunction = library.makeFunction(name: "bumpLight")
        pipeline.colorAttachments[0].pixelFormat = .bgra8Unorm
        let state = try device.makeRenderPipelineState(descriptor: pipeline)
        let spec = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 350, height: 405, mipmapped: false)
        spec.usage = [.renderTarget]
        spec.storageMode = .shared
        let texture = device.makeTexture(descriptor: spec)!
        struct Uniforms { var geometry, timing, origin: SIMD4<Float> }
        for variant: Float in [0, 4] {
          for effect in BumpEffect.allCases {
            for dark: Float in [0, 1] {
                for reduced: Float in [0, 1] {
                    let duration: Float = reduced == 1 ? 1.2 : Float(effect.duration)
                    for time: Float in [0, 0.7, duration] {
                        var uniforms = Uniforms(geometry: SIMD4(350, 405, 175, 78),
                                                timing: SIMD4(time, Float(effect.index) + variant, reduced, dark),
                                                origin: SIMD4(38, 292, 377, duration))
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture = texture
                        pass.colorAttachments[0].loadAction = .clear
                        pass.colorAttachments[0].storeAction = .store
                        let command = queue.makeCommandBuffer()!
                        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                        encoder.setRenderPipelineState(state)
                        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        encoder.endEncoding()
                        command.commit(); command.waitUntilCompleted()
                        expect(command.status == .completed, "GPU completed without error")
                        var pixels = [UInt8](repeating: 0, count: 350 * 405 * 4)
                        pixels.withUnsafeMutableBytes { bytes in
                            texture.getBytes(bytes.baseAddress!, bytesPerRow: 350 * 4,
                                             from: MTLRegionMake2D(0, 0, 350, 405), mipmapLevel: 0)
                        }
                        let alphas = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
                        if time == 0 || time == duration {
                            expect(alphas.allSatisfy { $0 == 0 }, "effect clears at both endpoints")
                        } else {
                            expect(alphas.filter { $0 > 0 }.count > 350 * 405 / 30, "light occupies the panel")
                            expect(alphas.filter { $0 > 225 }.count < 350 * 405 / 12,
                                   "opaque objects stay local; atmosphere preserves the interface")
                        }
                        var premultiplied = true
                        for pixel in stride(from: 0, to: pixels.count, by: 4) {
                            let alpha = pixels[pixel + 3]
                            if pixels[pixel] > alpha || pixels[pixel + 1] > alpha || pixels[pixel + 2] > alpha {
                                premultiplied = false
                            }
                        }
                        expect(premultiplied, "premultiplied alpha has no bright fringes")
                    }
                }
            }
          }
        }
        print("Bump effect checks passed: \(checks), including 96 Metal renders")
    }
}
