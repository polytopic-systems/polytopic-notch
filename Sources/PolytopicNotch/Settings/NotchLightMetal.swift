import AppKit
import Metal
import MetalKit
import SwiftUI

/// Draws the light picker's lit parts on the GPU: the glowing bar (bloom), the spectrum rail with its notch marker,
/// and the LED rows. The shaders are `NotchLight.metal`, shipped as a copied resource and compiled once at first use
/// (`MTLDevice.makeLibrary(source:)`), so building the package needs no Metal toolchain. Each view draws only when
/// its uniforms change (`MTKView` paused, `enableSetNeedsDisplay`): nothing runs while the picker sits still.
@MainActor
final class NotchLightMetal {
    /// The pipeline, or nil where Metal isn't available or the source doesn't compile (the picker draws with SwiftUI).
    static let shared: NotchLightMetal? = NotchLightMetal()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init?() {
        guard let source = Self.source, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { return nil }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "notchLightVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "notchLightFragment")
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
        self.device = device
        self.queue = queue
    }

    /// What one view draws. The layout matches `Uniforms` in `NotchLight.metal` (64 bytes).
    struct Uniforms: Equatable {
        enum Mode: Float { case bar = 0, rail = 1, leds = 2 }
        enum LEDKind: Float { case intensity = 0, whiteMix = 1 }

        /// Drawable size in pixels.
        var size = SIMD2<Float>(1, 1)
        /// Pixels per point.
        var scale: Float = 2
        var mode: Float = Mode.bar.rawValue
        /// The light, sRGB 0...1.
        var color = SIMD4<Float>(1, 1, 1, 1)
        /// Degrees.
        var hue: Float = 0
        /// Bar: 0.35...1, its width while breathing.
        var level: Float = 1
        /// Bar: 0...1, how far the bloom reaches.
        var glow: Float = 1
        /// LEDs: how many, and how many are lit.
        var count: Float = 16
        var lit: Float = 16
        var ledKind: Float = LEDKind.intensity.rawValue
        /// LEDs (intensity row): the saturation the white mix sets.
        var saturation: Float = 1
        /// Rail: 1 while the rail has keyboard focus (the marker turns bright white).
        var focused: Float = 0

        init(mode: Mode, color: NotchRGB, scale: CGFloat) {
            self.mode = mode.rawValue
            self.color = SIMD4(Float(color.red) / 255, Float(color.green) / 255, Float(color.blue) / 255, 1)
            self.scale = Float(scale)
        }
    }

    /// Encodes one frame into `pass`.
    func encode(_ uniforms: Uniforms, into pass: MTLRenderPassDescriptor, buffer: MTLCommandBuffer) {
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Draws into a fresh texture and returns its BGRA bytes (tests).
    func pixels(_ uniforms: Uniforms, width: Int, height: Int) -> [UInt8]? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        var sized = uniforms
        sized.size = SIMD2(Float(width), Float(height))
        encode(sized, into: pass, buffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    /// The shader source: `NotchLight.metal`, a copied resource (not compiled by the build).
    static var source: String? {
        Bundle.module.url(forResource: "NotchLight", withExtension: "metal").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// An `MTKView` that redraws only when `uniforms` change.
struct NotchLightMetalView: NSViewRepresentable {
    var renderer: NotchLightMetal
    var uniforms: NotchLightMetal.Uniforms

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = NotchLightMetal.pixelFormat
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.delegate = context.coordinator
        context.coordinator.uniforms = uniforms
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard context.coordinator.uniforms != uniforms else { return }
        context.coordinator.uniforms = uniforms
        view.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: NotchLightMetal
        var uniforms = NotchLightMetal.Uniforms(mode: .bar, color: NotchRGB(red: 255, green: 255, blue: 255), scale: 2)

        init(renderer: NotchLightMetal) { self.renderer = renderer }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

        func draw(in view: MTKView) {
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let buffer = renderer.queue.makeCommandBuffer() else { return }
            var frame = uniforms
            frame.size = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            frame.scale = Float(view.window?.backingScaleFactor ?? 2)
            renderer.encode(frame, into: pass, buffer: buffer)
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
