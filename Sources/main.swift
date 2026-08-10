import AppKit

if CommandLine.arguments.contains("--test") {
    do {
        try runOffscreenTest()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("test failed: \(error)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()   // never returns until quit; delegate stays alive for the app's lifetime
}
