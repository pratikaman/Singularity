import AppKit
import CoreMedia
import CoreVideo
import Metal
import ScreenCaptureKit

/// Streams the main display live (60 fps) as Metal textures, with this app's own
/// windows excluded from the capture — otherwise the overlay would capture itself
/// and recurse into an infinite mirror.
final class LiveScreenSource: NSObject, SCStreamOutput, SCStreamDelegate {
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "singularity.capture")
    private let lock = NSLock()
    // Keep the CVMetalTexture and pixel buffer alive as long as the texture is in use.
    private var latest: (texture: MTLTexture, backing: CVMetalTexture, buffer: CVPixelBuffer)?

    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    var onError: ((String) -> Void)?

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw SingularityError(message: "No display found")
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myApp = content.applications.filter { $0.processID == myPID }
        let filter = SCContentFilter(display: display, excludingApplications: myApp, exceptingWindows: [])

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        pixelWidth = config.width
        pixelHeight = config.height

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        lock.lock()
        latest = nil
        lock.unlock()
    }

    func latestTexture() -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return latest?.texture
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil,
                                                        .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }
        lock.lock()
        latest = (tex, cvTex, pb)
        lock.unlock()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }
}
