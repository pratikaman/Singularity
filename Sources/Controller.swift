import AppKit
import Metal
import MetalKit
import SwiftUI

final class OverlayWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class Controller: ObservableObject {
    @Published var intensity: Double = 1.0
    @Published var isRunning = false
    @Published var status = "Snapshots your screen, then devours it."

    weak var panel: NSWindow?
    private var overlay: OverlayWindow?
    private var renderer: BlackHoleRenderer?
    private var source: LiveScreenSource?
    private var escMonitor: Any?
    private var escGlobalMonitor: Any?

    func start() {
        guard !isRunning else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            status = "Allow Screen Recording in System Settings → Privacy & Security, then relaunch."
        } else {
            status = "Tuning in to the screen…"
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.beginEffect()
            } catch {
                self.status = "Capture failed — grant Screen Recording in System Settings → Privacy & Security, then relaunch."
                NSLog("Capture error: \(error)")
            }
        }
    }

    private func beginEffect() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SingularityError(message: "No Metal device")
        }
        let source = LiveScreenSource(device: device)
        source.onError = { [weak self] message in
            Task { @MainActor in self?.status = "Capture stopped: \(message)" }
        }
        try await source.start()

        // Wait for the first frame (up to ~3 s) so the overlay never flashes black.
        for _ in 0..<60 where source.latestTexture() == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard source.latestTexture() != nil else {
            source.stop()
            throw SingularityError(message: "No frames from the capture stream")
        }

        let renderer = try BlackHoleRenderer(device: device,
                                             width: source.pixelWidth,
                                             height: source.pixelHeight)
        renderer.liveTexture = { [weak source] in source?.latestTexture() }
        renderer.intensity = { [weak self] in Float(self?.intensity ?? 1) }
        renderer.onFinished = { [weak self] in
            self?.status = "Nothing remains. Reset to restore reality."
        }

        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        } ?? NSScreen.main
        guard let screen else { throw SingularityError(message: "No screen") }

        // Feed the pointer position to the shader's reality bubble
        // (mouseLocation is bottom-left origin; the shader's uv is y-down).
        let screenFrame = screen.frame
        renderer.mouseUV = {
            let loc = NSEvent.mouseLocation
            return SIMD2<Float>(Float((loc.x - screenFrame.minX) / screenFrame.width),
                                Float(1 - (loc.y - screenFrame.minY) / screenFrame.height))
        }

        let view = MTKView(frame: screen.frame, device: device)
        view.colorPixelFormat = MTLPixelFormat.bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.autoresizingMask = [.width, .height]
        view.delegate = renderer

        let overlay = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
        overlay.level = .screenSaver
        // Non-opaque so macOS doesn't mark the windows underneath as fully occluded —
        // occluded apps may pause rendering, which would freeze the "live" feed.
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        // Click-through: the desktop stays fully usable while it's being eaten —
        // clicks land on the real (live) windows underneath the show.
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlay.contentView = view
        overlay.onEscape = { [weak self] in self?.reset() }
        overlay.orderFrontRegardless()

        // keep the control panel reachable (and key) above the overlay
        panel?.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel?.makeKeyAndOrderFront(nil)

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, self?.isRunning == true {
                self?.reset()
                return nil
            }
            return e
        }
        // The overlay is click-through, so a click can focus another app and take
        // Esc with it. This global monitor catches Esc anyway — but macOS only
        // delivers global key events if the app has Accessibility trust, so the
        // floating Reset button stays the guaranteed way out.
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, self?.isRunning == true {
                self?.reset()
            }
        }

        self.overlay = overlay
        self.renderer = renderer
        self.source = source
        isRunning = true
        status = "Feeding… your Mac stays clickable. Esc or Reset restores it."
    }

    func reset() {
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
        if let m = escGlobalMonitor {
            NSEvent.removeMonitor(m)
            escGlobalMonitor = nil
        }
        overlay?.orderOut(nil)
        overlay?.contentView = nil
        overlay = nil
        renderer = nil
        source?.stop()
        source = nil
        panel?.level = .normal
        panel?.makeKeyAndOrderFront(nil)
        isRunning = false
        status = "Reality restored."
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller = Controller()
    var panel: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 340),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = "Singularity"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ControlView(c: controller))
        panel.center()
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        controller.panel = panel

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel {
            controller.reset()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let menubar = NSMenu()
        let appItem = NSMenuItem()
        menubar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Singularity",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menubar
    }
}
