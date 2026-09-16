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
        // The intentionally blurred gas needs less sampling than native text.
        // A 1.5x ceiling keeps the expansion within a 60 Hz GPU budget on Retina.
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
        do {
            guard let device = view.device else { throw ShaderError.unavailable }
            let renderer = try MetalRenderer(device: device)
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
            targetSize: targetSize, targetOffset: targetOffset
        )
        guard context.coordinator.renderer?.state != state else { return }
        context.coordinator.renderer?.state = state
        view.setNeedsDisplay(view.bounds)
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
}

// Layout mirrors the Metal struct, including its 8-byte alignment.
struct ShaderUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var inset: Float
    var nativeSurface: Float
    var scale: Float
    var variant: Float
    var targetSize: SIMD2<Float>
    var targetOffset: SIMD2<Float>
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
        guard let vertex = library.makeFunction(name: "fullScreenVertex"),
              let fragment = library.makeFunction(name: "waveFragment")
        else {
            throw ShaderError.missingFunction
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        // The shader writes premultiplied RGBA directly onto a transparent drawable.
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.commandQueue = queue
        super.init()
    }

    // MARK: Internal

    var state = ShaderState()
    let commandQueue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = commandQueue.makeCommandBuffer() else { return }
        let scale = Float(view.drawableSize.width / max(view.bounds.width, 1))
        self.encode(
            pass: pass,
            command: command,
            width: drawable.texture.width,
            height: drawable.texture.height,
            scale: scale
        )
        command.present(drawable)
        command.commit()
    }

    func encode(
        pass: MTLRenderPassDescriptor,
        command: MTLCommandBuffer,
        width: Int,
        height: Int,
        scale: Float
    ) {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = ShaderUniforms(
            resolution: SIMD2(Float(width), Float(height)), time: state.elapsed,
            inset: self.state.inset * scale, nativeSurface: self.state.nativeSurface ? 1 : 0, scale: scale,
            variant: Float(self.state.variant),
            targetSize: SIMD2(Float(self.state.targetSize.width), Float(self.state.targetSize.height)),
            targetOffset: SIMD2(Float(self.state.targetOffset.x), Float(self.state.targetOffset.y))
        )
        encoder.setRenderPipelineState(self.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
