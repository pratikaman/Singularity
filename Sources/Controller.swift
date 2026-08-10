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
    private var escMonitor: Any?

    func start() {
        guard !isRunning else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            status = "Allow Screen Recording in System Settings → Privacy & Security, then relaunch."
        } else {
            status = "Capturing screen…"
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await ScreenGrabber.captureMainDisplay()
                try self.beginEffect(with: image)
            } catch {
                self.status = "Capture failed — grant Screen Recording in System Settings → Privacy & Security, then relaunch."
                NSLog("Capture error: \(error)")
            }
        }
    }

    private func beginEffect(with image: CGImage) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SingularityError(message: "No Metal device")
        }
        let renderer = try BlackHoleRenderer(device: device, image: image)
        renderer.intensity = { [weak self] in Float(self?.intensity ?? 1) }
        renderer.onFinished = { [weak self] in
            self?.status = "Nothing remains. Reset to restore reality."
        }

        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        } ?? NSScreen.main
        guard let screen else { throw SingularityError(message: "No screen") }

        let view = MTKView(frame: screen.frame, device: device)
        view.colorPixelFormat = MTLPixelFormat.bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.autoresizingMask = [.width, .height]
        view.delegate = renderer

        let overlay = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
        overlay.level = .screenSaver
        overlay.isOpaque = true
        overlay.backgroundColor = .black
        overlay.hasShadow = false
        overlay.isReleasedWhenClosed = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlay.contentView = view
        overlay.onEscape = { [weak self] in self?.reset() }
        overlay.makeKeyAndOrderFront(nil)

        // keep the control panel reachable above the overlay
        panel?.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel?.orderFrontRegardless()

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, self?.isRunning == true {
                self?.reset()
                return nil
            }
            return e
        }

        self.overlay = overlay
        self.renderer = renderer
        isRunning = true
        status = "Feeding… Esc or Reset restores the screen."
    }

    func reset() {
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
        overlay?.orderOut(nil)
        overlay?.contentView = nil
        overlay = nil
        renderer = nil
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
