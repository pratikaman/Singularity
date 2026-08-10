import AppKit
import Metal
import MetalKit

struct SingularityError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class BlackHoleRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fieldInitPipeline: MTLRenderPipelineState
    private let fieldPipeline: MTLRenderPipelineState
    private let displayPipeline: MTLRenderPipelineState
    private var fieldA: MTLTexture
    private var fieldB: MTLTexture
    private var needsInit = true
    private let aspect: Float

    private(set) var progress: Float = 0
    private var simTime: Float = 0
    private var fullSince: Float = 0
    private var notified = false
    private var lastTime: CFTimeInterval?

    /// Baseline seconds from first bite to total darkness at 1.0x appetite.
    var duration: Float = 45
    var intensity: () -> Float = { 1 }
    var onFinished: (() -> Void)?
    /// Latest live capture frame; the sim holds (black screen) until this returns one.
    var liveTexture: () -> MTLTexture? = { nil }

    struct Uniforms {
        var hole: SIMD2<Float>
        var radius: Float
        var aspect: Float
        var dt: Float
        var time: Float
        var pull: Float
        var swirl: Float
        var progress: Float
        var pad: Float = 0
    }

    init(device: MTLDevice, width: Int, height: Int) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else {
            throw SingularityError(message: "No Metal command queue")
        }
        queue = q
        let lib = try device.makeLibrary(source: shaderSource, options: nil)

        func pipeline(_ frag: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fsq")
            d.fragmentFunction = lib.makeFunction(name: frag)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        fieldInitPipeline = try pipeline("fieldInitFrag", format: .rgba32Float)
        fieldPipeline = try pipeline("fieldFrag", format: .rgba32Float)
        displayPipeline = try pipeline("displayFrag", format: .bgra8Unorm)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                          width: width,
                                                          height: height,
                                                          mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        guard let a = device.makeTexture(descriptor: td),
              let b = device.makeTexture(descriptor: td) else {
            throw SingularityError(message: "Could not allocate flow-field textures")
        }
        fieldA = a
        fieldB = b
        aspect = Float(width) / Float(height)
        super.init()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        let now = CACurrentMediaTime()
        var dt = Float(lastTime.map { now - $0 } ?? 1.0 / 60.0)
        lastTime = now
        dt = min(max(dt, 0), 1.0 / 30.0)
        renderFrame(dt: dt * max(intensity(), 0.01), target: drawable.texture, drawable: drawable)
    }

    // MARK: - Simulation

    @discardableResult
    func renderFrame(dt: Float, target: MTLTexture, drawable: CAMetalDrawable?) -> MTLCommandBuffer? {
        guard let cb = queue.makeCommandBuffer() else { return nil }

        guard let live = liveTexture() else {
            // No capture frame yet — hold black, don't advance the meal.
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
            if let drawable { cb.present(drawable) }
            cb.commit()
            return cb
        }

        simTime += dt
        progress = min(simTime / duration, 1)

        let eased = progress * progress * (3 - 2 * progress)
        let radius = 0.03 + 1.35 * Float(pow(Double(progress), 3.0))
        let amp = 0.30 * (1 - eased)
        let hole = SIMD2<Float>(0.5 + amp * 1.15 * sin(simTime * 0.34 + 1.7),
                                0.5 + amp * sin(simTime * 0.24 + 0.6))

        var u = Uniforms(hole: hole, radius: radius, aspect: aspect, dt: dt,
                         time: simTime, pull: 0.6, swirl: 1.2, progress: progress)

        if needsInit {
            encode(cb, pipeline: fieldInitPipeline, textures: [], dest: fieldA, uniforms: &u)
            needsInit = false
        }
        encode(cb, pipeline: fieldPipeline, textures: [fieldA], dest: fieldB, uniforms: &u)
        encode(cb, pipeline: displayPipeline, textures: [fieldB, live], dest: target, uniforms: &u)
        swap(&fieldA, &fieldB)
        if let drawable { cb.present(drawable) }
        cb.commit()

        if progress >= 1 {
            fullSince += dt
            if fullSince > 2.0 && !notified {
                notified = true
                onFinished?()
            }
        }
        return cb
    }

    private func encode(_ cb: MTLCommandBuffer, pipeline: MTLRenderPipelineState,
                        textures: [MTLTexture], dest: MTLTexture, uniforms: inout Uniforms) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dest
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        for (i, tex) in textures.enumerated() {
            enc.setFragmentTexture(tex, index: i)
        }
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

/// Redraw any CGImage into a plain sRGB RGBA8 bitmap so MTKTextureLoader never
/// chokes on exotic formats (10-bit XDR etc.). Used by the --test path.
func normalizeImage(_ image: CGImage) -> CGImage {
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: image.width, height: image.height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage() ?? image
}
