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
    private let bakePipeline: MTLRenderPipelineState
    private let refinePipeline: MTLComputePipelineState
    private let shadePipeline: MTLRenderPipelineState
    private let bloomPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let displayPipeline: MTLRenderPipelineState

    private var fieldA: MTLTexture
    private var fieldB: MTLTexture
    private var needsInit = true
    private let aspect: Float

    /// Baked geodesics (bake.wgsl) + photon-ring refinement (refine.wgsl).
    private struct GSet {
        var hit1, hit2, sky, view: MTLTexture
        var aa, aaGeom: MTLTexture
        var gbuffer: [MTLTexture] { [hit1, hit2, sky, view] }
    }
    private var gFront: GSet
    private var gBack: GSet
    private let gW: Int
    private let gH: Int
    private let scene: MTLTexture
    private let layer: MTLTexture
    private let bloom: [(a: MTLTexture, ping: MTLTexture)]   // half, quarter, eighth
    private let noise: MTLTexture

    /// The bake is a 2D similarity of the image plane, so a G-buffer baked for
    /// one hole state is re-mapped for every other. The back set is re-baked
    /// continuously, one row slice per frame, then swapped in.
    private struct HoleState { var hole: SIMD2<Float>; var radius: Float }
    private var frontState: HoleState?
    private var backState = HoleState(hole: SIMD2<Float>(0.5, 0.5), radius: 0.03)
    private var bakeSlice = 0
    private(set) var bakePhase = 0   // 0 bake, 1 refine
    // ponytail: fixed slice count; adapt to GPU timing if a machine hitches
    private let bakeSliceCount = 12

    private(set) var progress: Float = 0
    private var simTime: Float = 0
    private var fullSince: Float = 0
    private var notified = false
    private var lastTime: CFTimeInterval?
    private var sceneYaw: Float = 0

    /// Baseline seconds from first bite to total darkness at 1.0x appetite.
    var duration: Float = 45
    var intensity: () -> Float = { 1 }
    var onFinished: (() -> Void)?
    /// Latest live capture frame; the sim holds (black screen) until this returns one.
    var liveTexture: () -> MTLTexture? = { nil }
    /// Called with each frame's command buffer just before commit (test-mode timing).
    var willCommit: ((MTLCommandBuffer) -> Void)?

    // vgpu settings.ts: cameraY / distance / diskRadius / cameraRoll / mouseYaw
    private let pitch: Float = 0.16
    private let orbit: Float = 13.5
    private let diskOuter: Float = 9
    private let roll: Float = -0.27
    private let mouseYaw: Float = 0.15
    private var tanPsi: Float { tan(asin(2.59807621 / orbit)) }

    struct Uniforms {
        var hole: SIMD2<Float>
        var radius: Float
        var aspect: Float
        var dt: Float
        var time: Float
        var pull: Float
        var swirl: Float
        var progress: Float
        var glowFade: Float
        var mouse: SIMD2<Float>
        var bakeHole: SIMD2<Float>
        var bakeRadius: Float
        var sceneYaw: Float
        var gRes: SIMD2<Float>
        var pitch: Float
        var orbit: Float
        var roll: Float
        var diskOuter: Float
        var tanPsi: Float
        var pad: Float = 0
    }

    struct BloomU {
        var sourceSize: SIMD2<Float>
        var direction: SIMD2<Float>
        var params: SIMD4<Float>
    }

    /// Pointer position in uv space (y down) for the reality bubble;
    /// defaults to offscreen so headless/test renders are unaffected.
    var mouseUV: () -> SIMD2<Float> = { SIMD2<Float>(-10, -10) }

    init(device: MTLDevice, width: Int, height: Int) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else {
            throw SingularityError(message: "No Metal command queue")
        }
        queue = q
        let lib = try device.makeLibrary(source: shaderSource, options: nil)

        func pipeline(_ frag: String, formats: [MTLPixelFormat]) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fsq")
            d.fragmentFunction = lib.makeFunction(name: frag)
            for (i, f) in formats.enumerated() { d.colorAttachments[i].pixelFormat = f }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let gFormats: [MTLPixelFormat] = [.rg32Float, .rg32Float, .rgba16Float, .rgba16Float]
        let aaFormats: [MTLPixelFormat] = [.rg8Unorm, .rgba16Float]
        fieldInitPipeline = try pipeline("fieldInitFrag", formats: [.rgba32Float])
        fieldPipeline = try pipeline("fieldFrag", formats: [.rgba32Float])
        bakePipeline = try pipeline("bakeFrag", formats: gFormats)
        guard let refineFn = lib.makeFunction(name: "refineKernel") else {
            throw SingularityError(message: "Missing refineKernel")
        }
        refinePipeline = try device.makeComputePipelineState(function: refineFn)
        shadePipeline = try pipeline("shadeFrag", formats: [.rgba16Float])
        bloomPipeline = try pipeline("bloomFrag", formats: [.rgba16Float])
        compositePipeline = try pipeline("compositeFrag", formats: [.rgba16Float])
        displayPipeline = try pipeline("displayFrag", formats: [.bgra8Unorm])

        func tex(_ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w,
                                                              height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead, .shaderWrite]
            td.storageMode = .private
            guard let t = device.makeTexture(descriptor: td) else {
                throw SingularityError(message: "Could not allocate a \(w)x\(h) texture")
            }
            return t
        }
        fieldA = try tex(.rgba32Float, width, height)
        fieldB = try tex(.rgba32Float, width, height)

        // The black hole renders at logical (non-retina) resolution, like vgpu
        // (dpr 1), and is upsampled in the display pass. The extra 8% per side is
        // the bake margin (BAKE_MARGIN in the shader).
        let gw = max(1, Int(Float(width) * 0.58)), gh = max(1, Int(Float(height) * 0.58))
        gW = gw
        gH = gh
        func gset() throws -> GSet {
            GSet(hit1: try tex(gFormats[0], gw, gh), hit2: try tex(gFormats[1], gw, gh),
                 sky: try tex(gFormats[2], gw, gh), view: try tex(gFormats[3], gw, gh),
                 aa: try tex(aaFormats[0], gw, gh), aaGeom: try tex(aaFormats[1], gw, gh))
        }
        gFront = try gset()
        gBack = try gset()
        scene = try tex(.rgba16Float, gw, gh)
        layer = try tex(.rgba16Float, gw, gh)
        var levels: [(a: MTLTexture, ping: MTLTexture)] = []
        for div in [2, 4, 8] {
            levels.append((a: try tex(.rgba16Float, max(1, gw / div), max(1, gh / div)),
                           ping: try tex(.rgba16Float, max(1, gw / div), max(1, gh / div))))
        }
        bloom = levels
        noise = try makeNoiseVolume(device: device)
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

    /// Hole position/size at a given sim time (pure, so the bake can predict ahead).
    private func holeState(at t: Float) -> HoleState {
        let p = min(t / duration, 1)
        let eased = p * p * (3 - 2 * p)
        let radius = 0.03 + 1.35 * Float(pow(Double(p), 3.0))
        let amp = 0.30 * (1 - eased)
        return HoleState(hole: SIMD2<Float>(0.5 + amp * 1.15 * sin(t * 0.34 + 1.7),
                                            0.5 + amp * sin(t * 0.24 + 0.6)),
                         radius: radius)
    }

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
        let state = holeState(at: simTime)
        let mouse = mouseUV()

        // pointer-driven disk yaw (vgpu mouseYaw), smoothed
        let yawTarget = (mouse.x >= 0 && mouse.x <= 1) ? (mouse.x * 2 - 1) * mouseYaw : 0
        sceneYaw += (yawTarget - sceneYaw) * (1 - exp(-dt / 0.325))

        var u = Uniforms(hole: state.hole, radius: state.radius, aspect: aspect, dt: dt,
                         time: simTime, pull: 0.6, swirl: 1.2, progress: progress,
                         glowFade: 1 - smoothstep(0.78, 0.98, progress),
                         mouse: mouse, bakeHole: state.hole, bakeRadius: state.radius,
                         sceneYaw: sceneYaw, gRes: SIMD2<Float>(Float(gW), Float(gH)),
                         pitch: pitch, orbit: orbit, roll: roll, diskOuter: diskOuter,
                         tanPsi: tanPsi)

        // progressive bake: first frame bakes everything at once, afterwards one
        // slice per frame, always aimed at where the hole will be when it's shown
        if frontState == nil {
            backState = state
            stepBake(cb, &u)
            stepBake(cb, &u)
        } else if progress < 0.98 {   // past that the shadow covers the screen
            stepBake(cb, &u)
        }
        guard let front = frontState else { return nil }
        u.bakeHole = front.hole
        u.bakeRadius = front.radius

        if needsInit {
            encode(cb, fieldInitPipeline, textures: [], dests: [fieldA], uniforms: u)
            needsInit = false
        }
        encode(cb, fieldPipeline, textures: [fieldA], dests: [fieldB], uniforms: u)

        // shade.wgsl → scene, bloom pyramid, composite.wgsl → layer
        encode(cb, shadePipeline, textures: gFront.gbuffer + [gFront.aa, gFront.aaGeom, noise],
               dests: [scene], uniforms: u)
        var src = scene
        for level in bloom {
            let size = SIMD2<Float>(Float(src.width), Float(src.height))
            let lsize = SIMD2<Float>(Float(level.a.width), Float(level.a.height))
            encode(cb, bloomPipeline, textures: [src], dests: [level.a],
                   uniforms: BloomU(sourceSize: size, direction: .zero, params: [0, 0.18, 1.5, 0]))
            encode(cb, bloomPipeline, textures: [level.a], dests: [level.ping],
                   uniforms: BloomU(sourceSize: lsize, direction: [1, 0], params: [-1, 0.18, 1.5, 1]))
            encode(cb, bloomPipeline, textures: [level.ping], dests: [level.a],
                   uniforms: BloomU(sourceSize: lsize, direction: [0, 1], params: [-1, 0.18, 1.5, 1]))
            src = level.a
        }
        encode(cb, compositePipeline, textures: [scene] + bloom.map { $0.a }, dests: [layer], uniforms: u)

        encode(cb, displayPipeline, textures: [fieldB, live, layer, gFront.sky], dests: [target], uniforms: u)
        swap(&fieldA, &fieldB)
        if let drawable { cb.present(drawable) }
        willCommit?(cb)
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

    /// Encodes one row slice of the back G-buffer's bake or refine pass; swaps
    /// the finished set to the front and starts the next bake.
    private func stepBake(_ cb: MTLCommandBuffer, _ u: inout Uniforms) {
        let slices = frontState == nil ? 1 : bakeSliceCount
        let rows = (gH + slices - 1) / slices
        let y0 = bakeSlice * rows
        let rect = MTLScissorRect(x: 0, y: y0, width: gW, height: min(rows, gH - y0))

        var ub = u
        ub.bakeHole = backState.hole
        ub.bakeRadius = backState.radius
        if bakePhase == 0 {
            encode(cb, bakePipeline, textures: [], dests: gBack.gbuffer, load: true, scissor: rect, uniforms: ub)
        } else if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(refinePipeline)
            for (i, t) in [gBack.hit1, gBack.sky, gBack.aa, gBack.aaGeom].enumerated() { enc.setTexture(t, index: i) }
            withUnsafeBytes(of: ub) { enc.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            var row = UInt32(rect.y)
            enc.setBytes(&row, length: 4, index: 1)
            enc.dispatchThreads(MTLSize(width: gW * 16, height: rect.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
            enc.endEncoding()
        }

        bakeSlice += 1
        if bakeSlice * rows >= gH {
            bakeSlice = 0
            bakePhase += 1
        }
        if bakePhase == 2 {
            bakePhase = 0
            swap(&gFront, &gBack)
            frontState = backState
            // aim the next bake at the moment it goes live: the hole only grows,
            // so the screen then always maps inside the baked area
            let lead = Float(2 * bakeSliceCount) * u.dt
            backState = holeState(at: simTime + lead)
        }
    }

    private func encode<T>(_ cb: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState,
                           textures: [MTLTexture], dests: [MTLTexture],
                           load: Bool = false, scissor: MTLScissorRect? = nil, uniforms: T) {
        let rpd = MTLRenderPassDescriptor()
        for (i, d) in dests.enumerated() {
            rpd.colorAttachments[i].texture = d
            rpd.colorAttachments[i].loadAction = load ? .load : .dontCare
            rpd.colorAttachments[i].storeAction = .store
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        if let scissor { enc.setScissorRect(scissor) }
        for (i, tex) in textures.enumerated() {
            enc.setFragmentTexture(tex, index: i)
        }
        withUnsafeBytes(of: uniforms) { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

private func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

/// vgpu's noise-volume.mjs: a deterministic 64³ tiled value-noise lattice
/// (r8unorm) the disk shader samples with repeat addressing.
private func makeNoiseVolume(device: MTLDevice) throws -> MTLTexture {
    let n = 64
    let seed = 13
    func fract(_ v: Float) -> Float { v - v.rounded(.down) }
    func hash31(_ x: Float, _ y: Float, _ z: Float) -> Float {
        var qx = fract(x * 0.1031), qy = fract(y * 0.103), qz = fract(z * 0.0973)
        let d = (qx * (qy + 33.33) + qy * (qz + 33.33)) + qz * (qx + 33.33)
        qx += d; qy += d; qz += d
        return fract((qx + qy) * qz)
    }
    func lattice(_ i: Int) -> Float { Float(i < n / 2 ? i : i - n) }
    var data = [UInt8](repeating: 0, count: n * n * n)
    var cursor = 0
    for z in 0..<n {
        let pz = lattice(z) + Float(seed * 1024)
        for y in 0..<n {
            let py = lattice(y)
            for x in 0..<n {
                data[cursor] = UInt8(min(255, Int((hash31(lattice(x), py, pz) * 255).rounded())))
                cursor += 1
            }
        }
    }
    let td = MTLTextureDescriptor()
    td.textureType = .type3D
    td.pixelFormat = .r8Unorm
    td.width = n; td.height = n; td.depth = n
    td.usage = .shaderRead
    td.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: td) else {
        throw SingularityError(message: "Could not allocate the noise volume")
    }
    data.withUnsafeBytes {
        tex.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: n, bytesPerImage: n * n)
    }
    return tex
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
