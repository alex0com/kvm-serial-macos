import AVFoundation
import AppKit
import KVMCore
import os

private let log = Logger(subsystem: "com.alex0com.kvm-serial-macos", category: "main")

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSMenuDelegate {
    let window: NSWindow
    private let renderer: VideoRenderer
    private let remoteView: RemoteView
    private let hud = LatencyHUD()
    private let input = InputController()
    private var capture: VideoCapture!

    // Serial
    private var device: CH9329Device?
    private var devicePath: String?
    private var chipInfo: CH9329Info?
    private var serialStatus = "Not connected"
    private var connecting = false

    // Video
    private var camera: AVCaptureDevice?
    private var format: VideoFormatChoice?
    private var videoStatus = "No video device"

    // HUD rates
    private var hudTimer: Timer?
    private var infoTimer: Timer?
    private var lastSample: (time: TimeInterval, packets: Int, frames: Int)?

    // Menus rebuilt on open
    private let serialMenu = NSMenu(title: "Serial Port")
    private let baudMenu = NSMenu(title: "Connect at Baud Rate")
    private let cameraMenu = NSMenu(title: "Video Device")
    private let formatMenu = NSMenu(title: "Video Format")
    private let layoutMenu = NSMenu(title: "Paste Layout")
    private var captureItem: NSMenuItem!
    private var pasteItem: NSMenuItem!

    init(renderer: VideoRenderer) {
        self.renderer = renderer
        remoteView = RemoteView(renderer: renderer)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()

        capture = VideoCapture { [renderer] pixelBuffer, timestamp in
            renderer.render(pixelBuffer, timestamp: timestamp)
        }
        renderer.onVideoSizeChange = { [weak self] size in
            Task { @MainActor in self?.videoSizeChanged(size) }
        }

        window.title = "KVM Serial"
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        window.delegate = self
        window.setFrameAutosaveName("KVMSerialMain")
        window.contentView = remoteView
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        if !window.setFrameUsingName("KVMSerialMain") { window.center() }

        hud.translatesAutoresizingMaskIntoConstraints = false
        remoteView.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: remoteView.leadingAnchor, constant: 8),
            hud.topAnchor.constraint(equalTo: remoteView.topAnchor, constant: 8),
        ])
        hud.isHidden = !Settings.showHUD
        remoteView.hideCursor = Settings.hideCursor

        input.window = window
        input.remoteView = remoteView
        input.onCaptureChange = { [weak self] in self?.updateCaptureState() }
        input.install()
        if Settings.captureSystemShortcuts { input.setSystemShortcutsEnabled(true) }
    }

    func start() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(remoteView)
        updateCaptureState()
        connectSerial()
        startVideo()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHUD() }
        }
        // Target LED / USB state for the HUD.
        infoTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollChipInfo() }
        }
    }

    func shutdown() {
        input.releaseAll()
        input.setSystemShortcutsEnabled(false)
        // Let the release reports go out before closing the port.
        let device = self.device
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { device?.close() }
        capture.stop()
    }

    // MARK: - Capture state

    /// Mac targets need relative motion while dragging (see HIDLink).
    private func applyDragMode() {
        let video = remoteView.videoSize
        device?.link.relativeDragScale = Settings.targetIsMac && video.width > 0
            ? (Double(video.width) / 4096, Double(video.height) / 4096) : nil
    }

    private func updateCaptureState() {
        let active = input.captureEnabled && device != nil
        input.link = active ? device?.link : nil
        remoteView.link = input.link
        remoteView.hideCursor = Settings.hideCursor && active
        captureItem?.state = input.captureEnabled ? .on : .off
        let state = input.captureEnabled
            ? "Input captured (⌃⌥Esc to release)" : "Input released (⌃⌥Esc to capture)"
        window.subtitle = device == nil ? serialStatus : state
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window.makeFirstResponder(remoteView)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    // MARK: - Serial

    /// Open the saved port, finding the chip's baud rate if the saved rate
    /// gets no reply.
    private func connectSerial(path: String? = nil, baud: Int? = nil) {
        guard !connecting else { return }
        let ports = SerialPort.availablePorts()
        guard let path = path ?? Settings.serialPort.flatMap({ ports.contains($0) ? $0 : nil })
            ?? ports.first(where: { $0.contains("usbserial") })
        else {
            serialStatus = "No serial port found"
            updateCaptureState()
            return
        }

        disconnectSerial()
        connecting = true
        serialStatus = "Connecting to \(path)…"
        updateCaptureState()

        let saved = baud ?? Settings.baudRate
        let candidates = [saved] + Settings.baudRates.reversed().filter { $0 != saved }
        let rates = baud != nil ? [saved] : candidates
        background {
            var result: Result<(CH9329Device, Int, CH9329Info?), Error> = .failure(
                CH9329Error("No reply from a CH9329 on \(path)."))
            for rate in rates {
                do {
                    let device = try CH9329Device(path: path, baudRate: rate)
                    // Retry once: the first request after opening is occasionally lost.
                    let info = device.getInfo(timeout: 0.3) ?? device.getInfo(timeout: 0.3)
                    // An explicitly chosen rate stays open even without a reply.
                    if info != nil || rates.count == 1 {
                        result = .success((device, rate, info))
                        break
                    }
                    device.close()
                } catch {
                    result = .failure(error)
                    break
                }
            }
            return result
        } then: { [weak self] result in
            self?.didConnect(path: path, result)
        }
    }

    private func didConnect(path: String, _ result: Result<(CH9329Device, Int, CH9329Info?), Error>) {
        connecting = false
        switch result {
        case .success(let (device, baud, info)):
            self.device = device
            devicePath = path
            chipInfo = info
            Settings.serialPort = path
            Settings.baudRate = baud
            serialStatus = info == nil
                ? "\(shortName(path)) @ \(baud) — no reply from chip" : "\(shortName(path)) @ \(baud)"
            device.link.onError = { error in log.error("Serial write failed: \(error, privacy: .public)") }
            applyDragMode()
            log.info("Connected \(path, privacy: .public) at \(baud) baud; chip info: \(String(describing: info), privacy: .public)")
        case .failure(let error):
            serialStatus = "\(error)"
            log.error("Serial connect failed: \(error, privacy: .public)")
        }
        updateCaptureState()
    }

    private func disconnectSerial() {
        input.releaseAll()
        input.link = nil
        remoteView.link = nil
        device?.close()
        device = nil
        chipInfo = nil
    }

    private func pollChipInfo() {
        guard let device, !hud.isHidden else { return }
        background {
            device.getInfo(timeout: 0.3)
        } then: { [weak self] info in
            guard let self, self.device === device else { return }
            chipInfo = info
        }
    }

    @objc private func selectSerialPort(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        connectSerial(path: path)
    }

    @objc private func selectBaud(_ sender: NSMenuItem) {
        connectSerial(path: devicePath, baud: sender.tag)
    }

    @objc private func refreshSerial(_ sender: Any?) {
        connectSerial(path: devicePath)
    }

    @objc private func changeChipBaud(_ sender: Any?) {
        guard let device, let path = devicePath, chipInfo != nil else {
            showAlert("Connect to a responding CH9329 first.", informative: serialStatus)
            return
        }
        let current = device.port.baudRate
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        for rate in [57600, 115200] where rate != current {
            popup.addItem(withTitle: "\(rate) baud")
            popup.lastItem?.tag = rate
        }
        let alert = NSAlert()
        alert.messageText = "Change the CH9329's baud rate?"
        alert.informativeText = """
            The chip is at \(current) baud. A faster rate cuts the time to send each mouse \
            packet (about 13.5 ms at 9600, 2.3 ms at 57600, 1.1 ms at 115200).

            The setting is stored on the chip. The CH9329 does not support 115200 when it \
            runs at 3.3 V; choose 57600 if you are not sure of your module's voltage.

            Any other software that talks to the chip will need the same rate afterwards.
            """
        alert.accessoryView = popup
        alert.addButton(withTitle: "Change")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let target = popup.selectedItem?.tag
        else { return }

        disconnectSerial()
        serialStatus = "Changing chip baud rate to \(target)…"
        updateCaptureState()
        connecting = true
        background {
            Result { try CH9329Device.changeBaudRate(path: path, from: current, to: target) }
        } then: { [weak self] result in
            guard let self else { return }
            connecting = false
            switch result {
            case .success(let info):
                Settings.baudRate = target
                connectSerial(path: path, baud: target)
                showAlert(
                    "The CH9329 now runs at \(target) baud.",
                    informative: "Chip version \(info.versionString), target USB "
                        + (info.usbConnected ? "connected." : "not connected."))
            case .failure(let error):
                connectSerial(path: path)
                showAlert("Could not change the baud rate.", informative: "\(error)")
            }
        }
    }

    // MARK: - Video

    private func startVideo() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            openCamera()
        case .notDetermined:
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted { self?.openCamera() } else { self?.videoStatus = "Camera access denied" }
            }
        default:
            videoStatus = "Camera access denied (System Settings › Privacy & Security › Camera)"
        }
    }

    private func openCamera(_ requested: AVCaptureDevice? = nil, format requestedFormat: VideoFormatChoice? = nil) {
        let devices = VideoCapture.devices()
        guard let camera = requested
            ?? devices.first(where: { $0.uniqueID == Settings.cameraID })
            ?? devices.first(where: { $0.localizedName == "USB3 Video" })
            ?? devices.first
        else {
            videoStatus = "No video device"
            return
        }
        let choices = VideoFormatChoice.choices(for: camera)
        guard let choice = requestedFormat
            ?? choices.first(where: { $0.key == Settings.videoFormat })
            ?? choices.first(where: { VideoFormatChoice.renderable.contains($0.subtype) })
            ?? choices.first
        else {
            videoStatus = "\(camera.localizedName) has no usable formats"
            return
        }

        self.camera = camera
        format = choice
        Settings.cameraID = camera.uniqueID
        videoStatus = "\(camera.localizedName) · \(choice.label)"
        log.info("Opening \(camera.localizedName, privacy: .public) as \(choice.label, privacy: .public)")
        capture.start(device: camera, choice: choice) { [weak self] error in
            guard let error else { return }
            log.error("Capture failed: \(error, privacy: .public)")
            let message = error.localizedDescription
            Task { @MainActor in self?.videoStatus = "Video error: \(message)" }
        }
    }

    private func videoSizeChanged(_ size: CGSize) {
        log.info("Video frames are \(Int(size.width))x\(Int(size.height))")
        let before = renderer.currentStats.framesPresented
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let stats = self?.renderer.currentStats else { return }
            let fps = Double(stats.framesPresented - before) / 5
            log.info("Video after 5 s: \(fps, format: .fixed(precision: 1)) fps presented, capture→screen \(stats.lastFrameAge * 1000, format: .fixed(precision: 1)) ms (delivered after \(stats.lastDeliveryAge * 1000, format: .fixed(precision: 1)) ms)")
        }
        remoteView.setVideoSize(size)
        applyDragMode()
        guard size.width > 0, size.height > 0 else { return }
        window.contentAspectRatio = size
        if !window.styleMask.contains(.fullScreen) { fitWindowToVideo(nil) }
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let camera = VideoCapture.devices().first(where: { $0.uniqueID == id })
        else { return }
        Settings.videoFormat = nil
        openCamera(camera)
    }

    @objc private func selectFormat(_ sender: NSMenuItem) {
        guard let camera, let key = sender.representedObject as? String,
            let choice = VideoFormatChoice.choices(for: camera).first(where: { $0.key == key })
        else { return }
        Settings.videoFormat = key
        openCamera(camera, format: choice)
    }

    // MARK: - Input actions

    @objc private func toggleCapture(_ sender: Any?) {
        input.setCaptureEnabled(!input.captureEnabled)
    }

    @objc private func toggleSwap(_ sender: NSMenuItem) {
        Settings.swapCommandControl.toggle()
        input.swapCommandControl = Settings.swapCommandControl
        sender.state = Settings.swapCommandControl ? .on : .off
    }

    @objc private func toggleTargetIsMac(_ sender: NSMenuItem) {
        Settings.targetIsMac.toggle()
        sender.state = Settings.targetIsMac ? .on : .off
        applyDragMode()
    }

    @objc private func toggleSystemShortcuts(_ sender: NSMenuItem) {
        if input.systemShortcutsActive {
            input.setSystemShortcutsEnabled(false)
            Settings.captureSystemShortcuts = false
        } else if input.setSystemShortcutsEnabled(true) {
            Settings.captureSystemShortcuts = true
        } else {
            InputController.requestAccessibility()
            showAlert(
                "Allow KVM Serial in Accessibility settings",
                informative: "Capturing ⌘Tab, ⌘Space and Mission Control shortcuts needs the "
                    + "Accessibility permission. Enable KVM Serial in System Settings › Privacy & "
                    + "Security › Accessibility, then choose this menu item again.")
        }
    }

    @objc private func sendCtrlAltDel(_ sender: Any?) {
        typealias M = HIDKeymap.Modifier
        let ctrlAlt = M.leftControl | M.leftAlt
        input.send(reports: [
            [M.leftControl, 0, 0, 0, 0, 0, 0, 0],
            [ctrlAlt, 0, 0, 0, 0, 0, 0, 0],
            [ctrlAlt, 0, HIDKeymap.deleteUsage, 0, 0, 0, 0, 0],
            [ctrlAlt, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ])
    }

    @objc private func pasteAsKeystrokes(_ sender: Any?) {
        guard let link = device?.link, let text = NSPasteboard.general.string(forType: .string),
            !text.isEmpty
        else { return }
        let layout = KeyboardLayouts.layout(Settings.pasteLayout)
        let release: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
        input.releaseAll()
        pasteItem.isEnabled = false
        // Match kvm-serial's paste pacing (10 ms per report) so every key down
        // and up is seen by the target's USB polling.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var skipped = 0
            for char in text {
                guard let report = KeyboardLayouts.report(for: char, layout: layout) else {
                    skipped += 1
                    continue
                }
                link.sendKeyboard(report)
                Thread.sleep(forTimeInterval: 0.01)
                link.sendKeyboard(release)
                Thread.sleep(forTimeInterval: 0.01)
            }
            if skipped > 0 { log.notice("Paste skipped \(skipped) characters not in the layout") }
            Task { @MainActor in self?.pasteItem.isEnabled = true }
        }
    }

    @objc private func selectPasteLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.pasteLayout = name
    }

    // MARK: - View actions

    @objc private func toggleHUD(_ sender: NSMenuItem) {
        Settings.showHUD.toggle()
        hud.isHidden = !Settings.showHUD
        sender.state = Settings.showHUD ? .on : .off
        if Settings.showHUD { pollChipInfo() }
    }

    @objc private func toggleHideCursor(_ sender: NSMenuItem) {
        Settings.hideCursor.toggle()
        sender.state = Settings.hideCursor ? .on : .off
        updateCaptureState()
    }

    /// Size the window to the video, scaled down to fit the screen.
    @objc private func fitWindowToVideo(_ sender: Any?) {
        let video = remoteView.videoSize
        guard video.width > 0, let screen = window.screen ?? NSScreen.main else { return }
        let scale = window.backingScaleFactor
        // 1 video pixel per screen pixel if it fits, otherwise 90% of the screen.
        let available = screen.visibleFrame.size
        let native = CGSize(width: video.width / scale, height: video.height / scale)
        let maxContent = window.contentRect(forFrameRect: NSRect(
            origin: .zero, size: CGSize(width: available.width * 0.9, height: available.height * 0.9)
        )).size
        let fitted = native.width <= maxContent.width && native.height <= maxContent.height
            ? native : aspectFit(video, in: maxContent).size
        window.setContentSize(fitted)
        if sender != nil { window.center() }
    }

    // MARK: - HUD

    private func updateHUD() {
        guard !hud.isHidden else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let video = renderer.currentStats
        let link = device?.link.currentStats ?? HIDLink.Stats()
        var fps = 0.0, pps = 0.0
        if let last = lastSample, now > last.time {
            fps = Double(video.framesPresented - last.frames) / (now - last.time)
            pps = Double(link.packetsSent - last.packets) / (now - last.time)
        }
        lastSample = (now, link.packetsSent, video.framesPresented)

        var lines: [String] = []
        if video.videoSize.width > 0 {
            lines.append(String(
                format: "Video  %@ · %.0f×%.0f %@ · %.1f fps · capture→screen %.1f ms (delivered %.1f ms)",
                camera?.localizedName ?? "?", video.videoSize.width, video.videoSize.height,
                fourCC(video.pixelFormat), fps, video.lastFrameAge * 1000, video.lastDeliveryAge * 1000))
        } else {
            lines.append("Video  \(videoStatus)")
        }
        if let device {
            let failed = device.failedReplyCount
            lines.append(String(
                format: "Serial %@ @ %d · %.0f pkt/s · %d moves merged · %d write errors · %d chip errors",
                shortName(device.port.path), device.port.baudRate, pps, link.movesCoalesced,
                link.errors, failed))
        } else {
            lines.append("Serial \(serialStatus)")
        }
        if let info = chipInfo {
            func led(_ on: Bool) -> String { on ? "●" : "○" }
            lines.append(
                "Target USB \(info.usbConnected ? "connected" : "not connected") · CH9329 v\(info.versionString)"
                    + " · Num \(led(info.numLock)) Caps \(led(info.capsLock)) Scroll \(led(info.scrollLock))")
        }
        lines.append(
            "Input  " + (input.captureEnabled ? "captured" : "released") + " (⌃⌥Esc)"
                + (input.systemShortcutsActive ? " · system shortcuts captured" : ""))
        hud.stringValue = lines.joined(separator: "\n")
    }

    // MARK: - Menus

    func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About KVM Serial",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide KVM Serial", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit KVM Serial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "KVM Serial")

        let deviceMenu = NSMenu(title: "Device")
        deviceMenu.addItem(submenu: serialMenu, title: "Serial Port")
        deviceMenu.addItem(submenu: baudMenu, title: "Connect at Baud Rate")
        deviceMenu.addItem(item("Change Chip Baud Rate…", #selector(changeChipBaud(_:))))
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(submenu: cameraMenu, title: "Video Device")
        deviceMenu.addItem(submenu: formatMenu, title: "Video Format")
        main.addItem(submenu: deviceMenu, title: "Device")
        [serialMenu, baudMenu, cameraMenu, formatMenu, layoutMenu].forEach { $0.delegate = self }

        let inputMenu = NSMenu(title: "Input")
        captureItem = item("Capture Keyboard and Mouse (⌃⌥Esc)", #selector(toggleCapture(_:)))
        inputMenu.addItem(captureItem)
        let macItem = item("Target Is a Mac (relative drags)", #selector(toggleTargetIsMac(_:)))
        macItem.state = Settings.targetIsMac ? .on : .off
        inputMenu.addItem(macItem)
        let swapItem = item("Send ⌘ as Ctrl", #selector(toggleSwap(_:)))
        swapItem.state = Settings.swapCommandControl ? .on : .off
        inputMenu.addItem(swapItem)
        let shortcutsItem = item("Capture System Shortcuts (⌘Tab, ⌘Space)", #selector(toggleSystemShortcuts(_:)))
        inputMenu.addItem(shortcutsItem)
        inputMenu.addItem(.separator())
        pasteItem = item("Paste as Keystrokes", #selector(pasteAsKeystrokes(_:)), key: "v")
        inputMenu.addItem(pasteItem)
        inputMenu.addItem(submenu: layoutMenu, title: "Paste Layout")
        inputMenu.addItem(item("Send Ctrl+Alt+Del", #selector(sendCtrlAltDel(_:))))
        main.addItem(submenu: inputMenu, title: "Input")
        inputMenu.delegate = self

        let viewMenu = NSMenu(title: "View")
        let hudItem = item("Show Latency HUD", #selector(toggleHUD(_:)), key: "l")
        hudItem.state = Settings.showHUD ? .on : .off
        viewMenu.addItem(hudItem)
        let cursorItem = item("Hide Cursor Over Video", #selector(toggleHideCursor(_:)))
        cursorItem.state = Settings.hideCursor ? .on : .off
        viewMenu.addItem(cursorItem)
        viewMenu.addItem(item("Fit Window to Video", #selector(fitWindowToVideo(_:)), key: "0"))
        viewMenu.addItem(.separator())
        let fullScreen = NSMenuItem(title: "Enter Full Screen",
                                    action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreen)
        main.addItem(submenu: viewMenu, title: "View")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Input" {
            captureItem.state = input.captureEnabled ? .on : .off
            menu.items.first { $0.action == #selector(toggleSystemShortcuts(_:)) }?.state =
                input.systemShortcutsActive ? .on : .off
            return
        }
        menu.removeAllItems()
        switch menu {
        case serialMenu:
            for path in SerialPort.availablePorts() {
                let entry = item(shortName(path), #selector(selectSerialPort(_:)))
                entry.representedObject = path
                entry.state = path == devicePath && device != nil ? .on : .off
                menu.addItem(entry)
            }
            if menu.items.isEmpty { menu.addItem(withTitle: "No serial ports", action: nil, keyEquivalent: "") }
            menu.addItem(.separator())
            menu.addItem(item("Reconnect", #selector(refreshSerial(_:))))
        case baudMenu:
            for rate in Settings.baudRates {
                let entry = item("\(rate)", #selector(selectBaud(_:)))
                entry.tag = rate
                entry.state = device?.port.baudRate == rate ? .on : .off
                menu.addItem(entry)
            }
        case cameraMenu:
            for cam in VideoCapture.devices() {
                let entry = item(cam.localizedName, #selector(selectCamera(_:)))
                entry.representedObject = cam.uniqueID
                entry.state = cam.uniqueID == camera?.uniqueID ? .on : .off
                menu.addItem(entry)
            }
            if menu.items.isEmpty { menu.addItem(withTitle: "No video devices", action: nil, keyEquivalent: "") }
        case formatMenu:
            guard let camera else { break }
            for choice in VideoFormatChoice.choices(for: camera) {
                let entry = item(choice.label, #selector(selectFormat(_:)))
                entry.representedObject = choice.key
                entry.state = choice.key == format?.key ? .on : .off
                menu.addItem(entry)
            }
        case layoutMenu:
            for name in KeyboardLayouts.available {
                let entry = item(name, #selector(selectPasteLayout(_:)))
                entry.representedObject = name
                entry.state = name == Settings.pasteLayout ? .on : .off
                menu.addItem(entry)
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    /// Run blocking work (serial requests) off the main thread and hand the
    /// result back on the main thread.
    private func background<T: Sendable>(
        _ work: @escaping @Sendable () -> T, then: @escaping @MainActor (T) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            Task { @MainActor in then(result) }
        }
    }

    private func showAlert(_ message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.beginSheetModal(for: window)
    }

    private func shortName(_ path: String) -> String {
        path.replacingOccurrences(of: "/dev/", with: "")
    }

    private func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
