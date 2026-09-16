import MetalKit
import SwiftUI

/// Light is a separate transparent surface. Native glass and text are never
/// captured into a texture or replaced by a layerEffect placeholder.
struct BumpMetalSurface: NSViewRepresentable {
    final class Coordinator {
        fileprivate var renderer: BumpLightRenderer?
    }

    var run: BumpEffectRun?
    var avatar: CGRect
    var origin: CGPoint
    var emojiBurst: Bool
    var dark: Bool
    var onFailure: (String) -> Void

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = BumpLightView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        do {
            guard let device = view.device else { throw BumpLightError.unavailable }
            let renderer = try BumpLightRenderer(device: device)
            renderer.onFailure = self.onFailure
            context.coordinator.renderer = renderer
            view.delegate = renderer
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { onFailure(message) }
            NSLog("Bump light: %@", message)
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.run = self.run
        renderer.avatar = self.avatar
        renderer.origin = self.origin
        renderer.emojiBurst = self.emojiBurst
        renderer.dark = self.dark
        let animating = self.run != nil && self.run?.frozenTime == nil
        view.enableSetNeedsDisplay = !animating
        view.isPaused = !animating
        if !animating { view.setNeedsDisplay(view.bounds) }
    }
}

private final class BumpLightView: MTKView {
    override var isOpaque: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

private enum BumpLightError: Error { case unavailable, missingSource, missingFunction }

private struct BumpLightUniforms {
    var geometry: SIMD4<Float>
    var timing: SIMD4<Float>
    var origin: SIMD4<Float>
}

private final class BumpLightRenderer: NSObject, MTKViewDelegate {
    // MARK: Lifecycle

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw BumpLightError.unavailable }
        self.queue = queue
        guard let url = Bundle.main.url(
            forResource: "BumpEffects",
            withExtension: "metal",
            subdirectory: "OnboardingShaders"
        )
        else { throw BumpLightError.missingSource }
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "bumpVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "bumpLight")
        guard descriptor.vertexFunction != nil,
              descriptor.fragmentFunction != nil else { throw BumpLightError.missingFunction }
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
        NSLog("Bump light: Metal pipeline ready")
    }

    // MARK: Internal

    var run: BumpEffectRun?
    var avatar = CGRect.zero
    var origin = CGPoint.zero
    var emojiBurst = false
    var dark = false
    var onFailure: ((String) -> Void)?

    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        // An idle draw clears the last frame. The display link is paused immediately afterward.
        if let run {
            var uniforms = BumpLightUniforms(
                geometry: SIMD4(
                    Float(view.bounds.width),
                    Float(view.bounds.height),
                    Float(self.avatar.midX),
                    Float(self.avatar.midY)
                ),
                timing: SIMD4(
                    Float(run.elapsed()),
                    Float(run.effect.index + (self.emojiBurst ? 4 : 0)),
                    run.reduced ? 1 : 0,
                    self.dark ? 1 : 0
                ),
                origin: SIMD4(
                    Float(self.avatar.width / 2),
                    Float(self.origin.x),
                    Float(self.origin.y),
                    Float(run.duration)
                )
            )
            encoder.setRenderPipelineState(self.pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BumpLightUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        command.addCompletedHandler { [weak self] completed in
            guard completed.status == .error else { return }
            let message = completed.error?.localizedDescription ?? "GPU command failed"
            DispatchQueue.main.async {
                guard let self, !self.reportedFailure else { return }
                self.reportedFailure = true
                self.onFailure?(message)
                NSLog("Bump light: %@", message)
            }
        }
        command.present(drawable)
        command.commit()
    }

    // MARK: Private

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var reportedFailure = false
}
