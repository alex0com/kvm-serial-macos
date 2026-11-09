import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let renderer: VideoRenderer
        do {
            renderer = try VideoRenderer()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not set up video rendering."
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let controller = MainWindowController(renderer: renderer)
        self.controller = controller
        NSApp.mainMenu = controller.buildMainMenu()
        controller.start()
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        // Give the release reports time to leave the serial port.
        Thread.sleep(forTimeInterval: 0.1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
