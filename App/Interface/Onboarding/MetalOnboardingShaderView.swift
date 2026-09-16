import MetalKit
import SwiftUI

private final class TransparentMetalView: MTKView {
    // MARK: Internal

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        self.updateResolution()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.updateResolution()
    }

    // MARK: Private

    private func updateResolution() {
        // Soft light needs less sampling than native text. A 1.5x ceiling keeps
        // the 28-sample volume within a 60 Hz GPU budget on Retina.
        let scale = min(window?.backingScaleFactor ?? 2, 1.5)
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if drawableSize != size { drawableSize = size }
    }
}

struct MetalOnboardingShaderView: NSViewRepresentable {
    final class Coordinator {
        var renderer: MetalRenderer?
    }

    let elapsed: Float
    let inset: Float
    let nativeSurface: Bool
    let variant: Int
    var rayLogoRect: CGRect = .zero
    var rayLogoExit: Float = 0
    var targetSize: CGSize = .zero
    var targetOffset: CGPoint = .zero
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = TransparentMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        // The mark and the SwiftUI name move as one piece: the drawable is
        // presented inside the same Core Animation transaction as the layout,
        // not one display cycle later.
        view.presentsWithTransaction = true
        do {
            guard let device = view.device else { throw ShaderError.unavailable }
            let renderer = try MetalRenderer(device: device)
            renderer.onFailure = self.onFailure
            context.coordinator.renderer = renderer
            view.delegate = renderer
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { onFailure(message) }
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let state = ShaderState(
            elapsed: elapsed, inset: inset, nativeSurface: nativeSurface, variant: variant,
            targetSize: targetSize, targetOffset: targetOffset, rayLogoRect: rayLogoRect, rayLogoExit: rayLogoExit
        )
        guard context.coordinator.renderer?.state != state else { return }
        context.coordinator.renderer?.state = state
        // Draw now, inside SwiftUI's own update, so the mark's new frame is
        // committed together with the text laid out next to it. A deferred
        // display pass would put the mark one or two frames behind the name.
        view.draw()
    }
}

enum ShaderError: Error {
    case unavailable, missingSource, missingFunction, renderFailed, invalidPixels(String)
}

struct ShaderState: Equatable {
    var elapsed: Float = 0
    var inset: Float = 34
    var nativeSurface = false
    var variant = 0
    var targetSize: CGSize = .zero
    var targetOffset: CGPoint = .zero
    /// The mark's slot; empty means the panel's default slot.
    var rayLogoRect: CGRect = .zero
    /// 0 while the settled mark stays, 1 once it has softened and faded away.
    var rayLogoExit: Float = 0
    /// Onboarding is presented in the dark appearance; the surface color follows it.
    var darkAppearance = true
    /// Verification only: freeze temporal noise while inspecting optical transport.
    var rayPhaseLock: Float = -1
    /// Verification only: compare the fading layer with its unattenuated rays.
    var rayOpacityOverride: Float = -1
    /// Verification only: hold the collection at a fixed progress.
    var rayLogoClipOverride: Float = -1
    /// Verification only: hold the same 3D volume at a fixed flashlight tilt.
    var rayLampTurnOverride: Float = -1
}

// Layout mirrors the Metal struct, including its 8-byte alignment.
struct ShaderUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var inset: Float
    var nativeSurface: Float
    var scale: Float
    var variant: Float
    var style: Float
    var targetSize: SIMD2<Float>
    var targetOffset: SIMD2<Float>
    var tuning: SIMD4<Float>
}

/// Ray / Flow only. Every other value the shader once compared is fixed here.
enum RayFlow {
    /// Metal dispatch id of the Ray style and of the Flow gesture.
    static let style: Float = 7
    static let transition: Float = 1
    /// Reach, definition, warmth, flow: the accepted texture.
    static let tuning = SIMD4<Float>(0.35, 1.0, 0.55, 0.58)
    /// Bloom is gone before the native handoff, so it can never differ between hosts.
    static let bloomEnd: Float = 1.95
}

final class MetalRenderer: NSObject, MTKViewDelegate {
    // MARK: Lifecycle

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw ShaderError.unavailable }
        guard let url = Bundle.main
            .url(forResource: "Waves", withExtension: "metal", subdirectory: "OnboardingShaders")
        else {
            throw ShaderError.missingSource
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        self.library = library
        guard let vertex = library.makeFunction(name: "fullScreenVertex"),
              let radiance = library.makeFunction(name: "rayRadianceFragment"),
              let composite = library.makeFunction(name: "rayCompositeFragment"),
              let extract = library.makeFunction(name: "rayBloomExtract"),
              let blur = library.makeFunction(name: "rayBloomBlur")
        else {
            throw ShaderError.missingFunction
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = radiance
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        self.rayPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        // The compositor writes premultiplied RGBA directly onto a transparent drawable.
        descriptor.fragmentFunction = composite
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.rayComposite = try device.makeRenderPipelineState(descriptor: descriptor)
        self.bloomExtract = try device.makeComputePipelineState(function: extract)
        self.bloomBlur = try device.makeComputePipelineState(function: blur)
        self.commandQueue = queue
        super.init()
    }

    // MARK: Internal

    var state = ShaderState()
    var onFailure: ((String) -> Void)?
    let commandQueue: MTLCommandQueue

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = commandQueue.makeCommandBuffer() else { return }
        let scale = Float(view.drawableSize.width / max(view.bounds.width, 1))
        do {
            try self.encode(
                pass: pass, command: command, width: drawable.texture.width,
                height: drawable.texture.height, scale: scale
            )
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
            return
        }
        command.addCompletedHandler { [weak self] completed in
            if completed.status == .error {
                let message = completed.error?.localizedDescription ?? "Metal command failed"
                DispatchQueue.main.async { self?.onFailure?(message) }
            }
        }
        // With presentsWithTransaction, present after the GPU work is scheduled
        // so the new frame lands in this transaction together with the text.
        command.commit()
        command.waitUntilScheduled()
        drawable.present()
    }

    /// Two passes: linear radiance into a private RGBA16Float target, then
    /// bloom, the whole-field condensation and the original mark on the drawable.
    func encode(
        pass: MTLRenderPassDescriptor,
        command: MTLCommandBuffer,
        width: Int,
        height: Int,
        scale: Float
    ) throws {
        var uniforms = ShaderUniforms(
            resolution: SIMD2(Float(width), Float(height)), time: self.state.elapsed,
            inset: self.state.inset * scale, nativeSurface: self.state.nativeSurface ? 1 : 0, scale: scale,
            variant: Float(self.state.variant), style: RayFlow.style,
            targetSize: SIMD2(Float(self.state.targetSize.width), Float(self.state.targetSize.height)),
            targetOffset: SIMD2(Float(self.state.targetOffset.x), Float(self.state.targetOffset.y)),
            tuning: RayFlow.tuning
        )
        let targets = try self.targets(width: width, height: height)
        let hdrPass = MTLRenderPassDescriptor()
        hdrPass.colorAttachments[0].texture = targets.radiance
        hdrPass.colorAttachments[0].loadAction = .dontCare
        hdrPass.colorAttachments[0].storeAction = .store
        guard let volume = command.makeRenderCommandEncoder(descriptor: hdrPass) else { throw ShaderError.renderFailed }
        volume.label = "Ray · 28-sample light volume"
        volume.setRenderPipelineState(self.rayPipeline)
        volume.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        var palette = RayPalette.amethyst
        volume.setFragmentBytes(&palette, length: MemoryLayout<RayPaletteUniforms>.stride, index: 1)
        var transition = SIMD4<Float>(
            RayFlow.transition, self.state.rayPhaseLock, self.state.darkAppearance ? 1 : 0,
            self.state.rayOpacityOverride
        )
        volume.setFragmentBytes(&transition, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        if self.logoAsset == nil { self.logoAsset = try RayLogoAsset(device: self.commandQueue.device) }
        guard let logoAsset else { throw ShaderError.missingSource }
        var logo = logoAsset.uniforms(state: self.state)
        volume.setFragmentBytes(&logo, length: MemoryLayout<RayLogoUniforms>.stride, index: 3)
        volume.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        volume.endEncoding()

        if !self.state.nativeSurface, self.state.elapsed < RayFlow.bloomEnd {
            try self.compute(command, self.bloomExtract, input: targets.radiance, output: targets.bright)
            try self.compute(
                command,
                self.bloomBlur,
                input: targets.bright,
                output: targets.scratch,
                axis: SIMD2(scale, 0)
            )
            try self.compute(
                command,
                self.bloomBlur,
                input: targets.scratch,
                output: targets.bloom,
                axis: SIMD2(0, scale)
            )
        }
        guard let composite = command.makeRenderCommandEncoder(descriptor: pass) else { throw ShaderError.renderFailed }
        composite.label = "Ray · bloom, condensation into the mark, native window color"
        composite.setRenderPipelineState(self.rayComposite)
        composite.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        var surface = RaySurface.uniforms(dark: self.state.darkAppearance)
        composite.setFragmentBytes(&surface, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        composite.setFragmentBytes(&transition, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        composite.setFragmentBytes(&logo, length: MemoryLayout<RayLogoUniforms>.stride, index: 3)
        composite.setFragmentTexture(targets.radiance, index: 0)
        composite.setFragmentTexture(targets.bloom, index: 1)
        composite.setFragmentTexture(logoAsset.color, index: 2)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
    }

    // MARK: Private

    private struct RayTargets {
        let radiance: MTLTexture
        let bright: MTLTexture
        let scratch: MTLTexture
        let bloom: MTLTexture
    }

    private let library: MTLLibrary
    private let rayPipeline: MTLRenderPipelineState
    private let rayComposite: MTLRenderPipelineState
    private let bloomExtract: MTLComputePipelineState
    private let bloomBlur: MTLComputePipelineState
    private var logoAsset: RayLogoAsset?
    private var rayTargets: RayTargets?

    /// Private, reusable GPU textures; bloom runs at quarter resolution.
    private func targets(width: Int, height: Int) throws -> RayTargets {
        if let rayTargets, rayTargets.radiance.width == width, rayTargets.radiance.height == height {
            return rayTargets
        }
        func texture(_ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = usage
            guard let result = commandQueue.device.makeTexture(descriptor: descriptor) else {
                throw ShaderError.renderFailed
            }
            result.label = label
            return result
        }
        let w = max(1, (width + 3) / 4), h = max(1, (height + 3) / 4)
        let result = try RayTargets(
            radiance: texture(width, height, [.renderTarget, .shaderRead], "Ray linear radiance"),
            bright: texture(w, h, [.shaderRead, .shaderWrite], "Ray bloom bright pass"),
            scratch: texture(w, h, [.shaderRead, .shaderWrite], "Ray horizontal bloom"),
            bloom: texture(w, h, [.shaderRead, .shaderWrite], "Ray vertical bloom")
        )
        self.rayTargets = result
        return result
    }

    private func compute(
        _ command: MTLCommandBuffer,
        _ pipeline: MTLComputePipelineState,
        input: MTLTexture,
        output: MTLTexture,
        axis: SIMD2<Float>? = nil
    ) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw ShaderError.renderFailed }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        if var axis { encoder.setBytes(&axis, length: MemoryLayout<SIMD2<Float>>.stride, index: 0) }
        let w = pipeline.threadExecutionWidth
        let h = min(8, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(
            MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
        )
        encoder.endEncoding()
    }
}
