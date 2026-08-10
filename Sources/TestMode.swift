import AppKit
import CoreText
import ImageIO
import Metal
import MetalKit

// Headless verification: `Singularity --test --out=/some/dir` runs the simulation
// offscreen against a synthetic desktop image and writes checkpoint PNGs.
// No screen-recording permission needed.

func runOffscreenTest() throws {
    let outDir = CommandLine.arguments
        .first(where: { $0.hasPrefix("--out=") })
        .map { String($0.dropFirst(6)) } ?? FileManager.default.currentDirectoryPath
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    guard let device = MTLCreateSystemDefaultDevice() else {
        throw SingularityError(message: "No Metal device")
    }
    let img = makeTestImage(width: 1600, height: 1000)
    let renderer = try BlackHoleRenderer(device: device, width: img.width, height: img.height)
    renderer.intensity = { 1 }
    // Static stand-in for the live capture stream — same code path, frame never changes.
    let loader = MTKTextureLoader(device: device)
    let staticTex = try loader.newTexture(cgImage: normalizeImage(img),
                                          options: [MTKTextureLoader.Option.SRGB: false])
    renderer.liveTexture = { staticTex }

    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                        width: img.width, height: img.height,
                                                        mipmapped: false)
    desc.usage = [.renderTarget]
    desc.storageMode = .shared
    guard let target = device.makeTexture(descriptor: desc) else {
        throw SingularityError(message: "No offscreen target")
    }

    let checkpoints: [Float] = [0.04, 0.15, 0.30, 0.50, 0.70, 0.85, 0.95, 1.0]
    var next = 0
    var frame = 0
    let dt: Float = 1.0 / 30.0
    while next < checkpoints.count && frame < 20000 {
        let cb = renderer.renderFrame(dt: dt, target: target, drawable: nil)
        if renderer.progress >= checkpoints[next] {
            cb?.waitUntilCompleted()
            let path = "\(outDir)/frame_\(String(format: "%03d", Int(checkpoints[next] * 100))).png"
            try savePNG(texture: target, to: path)
            print("progress \(checkpoints[next]) -> \(path)")
            next += 1
        }
        frame += 1
    }
    // let it settle 2s past completion, confirm final black
    for _ in 0..<59 { renderer.renderFrame(dt: dt, target: target, drawable: nil) }
    let cb = renderer.renderFrame(dt: dt, target: target, drawable: nil)
    cb?.waitUntilCompleted()
    try savePNG(texture: target, to: "\(outDir)/frame_end.png")
    print("done, \(frame) frames")
}

func makeTestImage(width: Int, height: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let w = CGFloat(width), h = CGFloat(height)

    let grad = CGGradient(colorsSpace: cs,
                          colors: [CGColor(red: 0.07, green: 0.10, blue: 0.22, alpha: 1),
                                   CGColor(red: 0.16, green: 0.06, blue: 0.26, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: h), options: [])

    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    ctx.setLineWidth(1)
    for x in stride(from: 0, through: width, by: 100) {
        ctx.move(to: CGPoint(x: CGFloat(x), y: 0)); ctx.addLine(to: CGPoint(x: CGFloat(x), y: h))
    }
    for y in stride(from: 0, through: height, by: 100) {
        ctx.move(to: CGPoint(x: 0, y: CGFloat(y))); ctx.addLine(to: CGPoint(x: w, y: CGFloat(y)))
    }
    ctx.strokePath()

    var seed: UInt64 = 42
    func rnd() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) % 10000) / 10000
    }
    for _ in 0..<45 {
        ctx.setFillColor(CGColor(red: 0.3 + rnd() * 0.7, green: 0.3 + rnd() * 0.7,
                                 blue: 0.3 + rnd() * 0.7, alpha: 0.9))
        let rect = CGRect(x: rnd() * w, y: rnd() * h,
                          width: 40 + rnd() * 180, height: 30 + rnd() * 120)
        if rnd() < 0.5 { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
    }

    let str = NSAttributedString(string: "SINGULARITY",
                                 attributes: [.font: NSFont.boldSystemFont(ofSize: 130),
                                              .foregroundColor: NSColor.white])
    let line = CTLineCreateWithAttributedString(str)
    ctx.textPosition = CGPoint(x: 220, y: h / 2 - 45)
    CTLineDraw(line, ctx)

    return ctx.makeImage()!
}

func savePNG(texture: MTLTexture, to path: String) throws {
    let w = texture.width, h = texture.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
    guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs, bitmapInfo: info),
          let cg = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     "public.png" as CFString, 1, nil)
    else { throw SingularityError(message: "PNG export failed for \(path)") }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}
