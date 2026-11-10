import AppKit
import AVFoundation
import CoreAudio
import CoreMediaIO
import CoreGraphics

// Runnable without Xcode: same overlay + CoreAudio/CoreMediaIO detection as the forked app.
// Build: swiftc -O -framework AppKit -framework AVFoundation -framework CoreAudio -framework CoreMediaIO -framework CoreGraphics -o live-tint main.swift
// Quit: pkill -f live-tint

enum MenuBarTintColor { case off, orange, green }

final class MenuBarTintOverlay {
    static let shared = MenuBarTintOverlay()
    var dripBelowBar: CGFloat = 8
    var alpha: CGFloat = 0.45
    private var panels: [NSPanel] = []
    private var views: [TintView] = []
    private var current: MenuBarTintColor = .off

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        rebuild()
    }

    func stop() {
        apply(.off)
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
    }

    func apply(_ color: MenuBarTintColor) {
        current = color
        if panels.isEmpty { rebuild() }
        let fill: NSColor
        switch color {
        case .off: fill = .clear
        case .orange: fill = NSColor.systemOrange.withAlphaComponent(alpha)
        case .green: fill = NSColor.systemGreen.withAlphaComponent(alpha)
        }
        views.forEach { $0.fillColor = fill }
        if color != .off { panels.forEach { $0.orderFrontRegardless() } }
        fputs("tint=\(color)\n", stderr)
    }

    private var level: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
    }

    @objc private func rebuild() {
        let prev = current
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        for screen in NSScreen.screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            var barH = frame.maxY - visible.maxY
            if barH < 1 { barH = max(screen.safeAreaInsets.top, 28) }
            let h = barH + dripBelowBar
            let rect = NSRect(x: frame.minX, y: frame.maxY - h, width: frame.width, height: h)
            let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.setFrame(rect, display: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = level
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            let view = TintView(frame: NSRect(origin: .zero, size: rect.size))
            panel.contentView = view
            panels.append(panel)
            views.append(view)
            panel.orderFrontRegardless()
        }
        apply(prev)
    }
}

private final class TintView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { fillColor.setFill(); bounds.fill() }
    override var acceptsFirstResponder: Bool { false }
}

final class MonitoredDevice {
    let device: AVCaptureDevice
    let isVideo: Bool
    let connectionID: UInt32
    private var isRunning = false
    private var audioListenerBlock: AudioObjectPropertyListenerBlock?
    private var videoListenerBlock: CMIOObjectPropertyListenerBlock?
    private let onStateChange: (MonitoredDevice, Bool) -> Void

    init?(device: AVCaptureDevice, onStateChange: @escaping (MonitoredDevice, Bool) -> Void) {
        self.device = device
        self.isVideo = device.hasMediaType(.video)
        self.onStateChange = onStateChange
        let selector = NSSelectorFromString("connectionID")
        guard device.responds(to: selector),
              let num = device.value(forKey: "connectionID") as? NSNumber else { return nil }
        self.connectionID = num.uint32Value
    }

    func startMonitoring() {
        isRunning = queryIsRunning()
        if isVideo {
            var addr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kAudioObjectPropertyElementMain)
            )
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleChange() }
            videoListenerBlock = block
            _ = CMIOObjectAddPropertyListenerBlock(connectionID, &addr, DispatchQueue.main, block)
        } else {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleChange() }
            audioListenerBlock = block
            _ = AudioObjectAddPropertyListenerBlock(connectionID, &addr, DispatchQueue.main, block)
        }
    }

    func stopMonitoring() {
        if isVideo, let block = videoListenerBlock {
            var addr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kAudioObjectPropertyElementMain)
            )
            CMIOObjectRemovePropertyListenerBlock(connectionID, &addr, DispatchQueue.main, block)
        } else if let block = audioListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(connectionID, &addr, DispatchQueue.main, block)
        }
    }

    func queryIsRunning() -> Bool {
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status: OSStatus
        if isVideo {
            var addr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kAudioObjectPropertyElementMain)
            )
            status = CMIOObjectGetPropertyData(connectionID, &addr, 0, nil, size, &size, &val)
        } else {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            status = AudioObjectGetPropertyData(connectionID, &addr, 0, nil, &size, &val)
        }
        return status == noErr && val != 0
    }

    private func handleChange() {
        let next = queryIsRunning()
        guard next != isRunning else { return }
        isRunning = next
        onStateChange(self, next)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitors: [String: MonitoredDevice] = [:]
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MenuBarTintOverlay.shared.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎙"
        item.button?.toolTip = "live-tint — mic→orange, cam→green (q to quit via menu)"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit live-tint", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        NotificationCenter.default.addObserver(self, selector: #selector(devConnected(_:)), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(devDisconnected(_:)), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)

        discover()
        refreshTint()
        fputs("live-tint running — open a call / QuickTime to test. Menu → Quit.\n", stderr)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuBarTintOverlay.shared.stop()
        monitors.values.forEach { $0.stopMonitoring() }
        monitors.removeAll()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func discover() {
        let audio = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        let video = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
        for device in audio.devices + video.devices {
            monitor(device)
        }
    }

    private func monitor(_ device: AVCaptureDevice) {
        guard monitors[device.uniqueID] == nil else { return }
        guard let m = MonitoredDevice(device: device, onStateChange: { [weak self] _, _ in
            self?.refreshTint()
        }) else { return }
        monitors[device.uniqueID] = m
        m.startMonitoring()
        fputs("watch \(device.hasMediaType(.video) ? "cam" : "mic"): \(device.localizedName)\n", stderr)
    }

    @objc private func devConnected(_ note: Notification) {
        if let d = note.object as? AVCaptureDevice { monitor(d); refreshTint() }
    }

    @objc private func devDisconnected(_ note: Notification) {
        if let d = note.object as? AVCaptureDevice {
            monitors[d.uniqueID]?.stopMonitoring()
            monitors.removeValue(forKey: d.uniqueID)
            refreshTint()
        }
    }

    private func refreshTint() {
        var mic = false, cam = false
        for m in monitors.values where m.queryIsRunning() {
            if m.isVideo { cam = true } else { mic = true }
        }
        if cam {
            MenuBarTintOverlay.shared.apply(.green)
            statusItem?.button?.title = "🟢"
        } else if mic {
            MenuBarTintOverlay.shared.apply(.orange)
            statusItem?.button?.title = "🟠"
        } else {
            MenuBarTintOverlay.shared.apply(.off)
            statusItem?.button?.title = "🎙"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
