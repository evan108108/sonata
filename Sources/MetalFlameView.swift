import AppKit
import Foundation
import Metal
import MetalKit
import SwiftUI

// MARK: - MetalFlameView
//
// SwiftUI wrapper around an MTKView that runs the ported "House fire" shader
// (Sources/Sonata/Resources/shaders/HouseFire.metal). Used by StartupGate as
// the foreground flame when Metal is available; the Canvas-based FlameAura
// remains the fallback for the cold-compile window and for any platform
// where Metal initialization fails.
//
// Lifecycle:
//   - StartupGate first calls `MetalFlameView.preflight()` on a background
//     Task. If the shader compiles, it sets metalReady = true and the view
//     is mounted; otherwise it stays on Canvas and logs the error.
//   - On `makeNSView`, the Coordinator builds the pipeline (the library is
//     already cached from preflight, so this is sub-millisecond), starts the
//     render loop, and installs an NSEvent monitor for mouse-moved/drag so
//     drags swirl the flames.
//   - On `dismantleNSView`, the MTKView is paused, the event monitor is
//     removed, and the Coordinator drops its references — no background
//     GPU/CPU once the loader dismisses.

struct MetalFlameView: NSViewRepresentable {

    // MARK: Preflight (compile test)
    //
    // Performs a one-time shader compile on a background queue. Caches the
    // resulting MTLLibrary so the view's Coordinator can re-use it without
    // re-parsing. Returns false if Metal or the shader source isn't
    // available — caller should fall back to the Canvas FlameAura.
    static func preflight() async -> Bool {
        await Self.compileCache.compileIfNeeded()
    }

    // Singleton actor that owns the compiled library so we only pay the
    // ~50–200ms metal-compile cost once per app launch.
    private actor CompileCache {
        var device: MTLDevice?
        var library: MTLLibrary?
        var attempted = false

        func compileIfNeeded() -> Bool {
            if let _ = library { return true }
            if attempted { return false }
            attempted = true

            guard let d = MTLCreateSystemDefaultDevice() else {
                NSLog("[MetalFlameView] preflight: no Metal device available")
                return false
            }
            guard let url = Bundle.module.url(forResource: "HouseFire", withExtension: "metal",
                                              subdirectory: "shaders"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                NSLog("[MetalFlameView] preflight: HouseFire.metal missing from bundle")
                return false
            }
            do {
                let lib = try d.makeLibrary(source: source, options: nil)
                self.device = d
                self.library = lib
                return true
            } catch {
                NSLog("[MetalFlameView] preflight: shader compile failed — \(error)")
                return false
            }
        }

        func materials() -> (MTLDevice, MTLLibrary)? {
            guard let d = device, let l = library else { return nil }
            return (d, l)
        }
    }

    private static let compileCache = CompileCache()

    // MARK: NSViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // CAMetalLayer is what backs MTKView. Making the layer non-opaque is
        // what lets the shader's transparent pixels composite over the
        // SwiftUI gradient behind. Without this the layer would draw solid
        // black where the shader emits alpha=0.
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.isOpaque = false

        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Nothing to update — uniforms are sourced from the Coordinator's
        // mutable state, which is mutated by the mouse monitor and the
        // CACurrentMediaTime() clock.
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.detach(from: nsView)
    }

    // MARK: - Coordinator (renderer + mouse monitor)

    final class Coordinator: NSObject, MTKViewDelegate {
        // Uniforms struct must match HouseFire.metal exactly (incl. padding).
        // 32 bytes: float2 resolution + float2 mouse + float time + float pad.
        private struct Uniforms {
            var resolution: SIMD2<Float>
            var mouse: SIMD2<Float>
            var time: Float
            var pad: Float
        }

        private var device: MTLDevice?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?

        private var startTime: CFTimeInterval = 0
        private var mousePos: SIMD2<Float> = .zero  // pixels, y measured from BOTTOM
        private weak var view: MTKView?
        private var eventMonitor: Any?

        func attach(to view: MTKView) {
            self.view = view
            self.startTime = CACurrentMediaTime()
            // Idle until materials are ready; the Task below flips us on.
            view.isPaused = true
            view.enableSetNeedsDisplay = false

            Task { [weak self, weak view] in
                guard let self = self,
                      let view = view,
                      let (device, library) = await MetalFlameView.compileCache.materials() else {
                    return
                }
                await MainActor.run {
                    self.installRenderer(view: view, device: device, library: library)
                }
            }
        }

        @MainActor
        private func installRenderer(view: MTKView, device: MTLDevice, library: MTLLibrary) {
            view.device = device
            self.device = device
            self.queue = device.makeCommandQueue()

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fire_vs")
            desc.fragmentFunction = library.makeFunction(name: "fire_fs")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            // Premultiplied-alpha blending so the shader's transparent
            // regions show the SwiftUI gradient behind the MTKView.
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            do {
                self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                NSLog("[MetalFlameView] pipeline build failed — \(error)")
                return
            }

            view.delegate = self
            view.isPaused = false
            installMouseMonitor()
        }

        func detach(from view: MTKView) {
            view.isPaused = true
            view.delegate = nil
            if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
            self.pipeline = nil
            self.queue = nil
            self.device = nil
            self.view = nil
        }

        private func installMouseMonitor() {
            // Local monitor: only fires while our app has focus and the
            // event isn't claimed by another responder upstream. We always
            // return the event so other handlers (Skip button, Escape key
            // monitor in StartupGate) still see it.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                self?.handle(event: event)
                return event
            }
        }

        private func handle(event: NSEvent) {
            guard let view = view, let window = view.window else { return }
            // event.locationInWindow is window coordinates (y-up from bottom-left
            // on macOS). Convert to view-local, then to pixels.
            let windowPt = event.locationInWindow
            let viewPt = view.convert(windowPt, from: nil)
            let scale = Float(window.backingScaleFactor)
            // viewPt.y is bottom-origin already, matching Shadertoy's iMouse.
            mousePos = SIMD2<Float>(Float(viewPt.x) * scale, Float(viewPt.y) * scale)
        }

        // MARK: MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // No-op: uniforms are rebuilt every frame from view.drawableSize.
        }

        func draw(in view: MTKView) {
            guard let queue = queue,
                  let pipeline = pipeline,
                  let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let cb = queue.makeCommandBuffer(),
                  let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
                return
            }

            let size = view.drawableSize
            var u = Uniforms(
                resolution: SIMD2<Float>(Float(size.width), Float(size.height)),
                mouse: mousePos,
                time: Float(CACurrentMediaTime() - startTime),
                pad: 0
            )

            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }
    }
}
