import AppKit
import AVFoundation
import CoreAudio
import CoreMediaIO
import CoreGraphics

// Runnable without Xcode: same overlay + CoreAudio/CoreMediaIO detection as the forked app.
// Build: swiftc -O -framework AppKit -framework AVFoundation -framework CoreAudio -framework CoreMediaIO -framework CoreGraphics -o live-tint main.swift
// Quit: pkill -f live-tint

enum MenuBarTintColor { case off, orange, green }

/// Height is dynamic + per-screen: frame.maxY - visibleFrame.maxY (live menu-bar band).
final class MenuBarTintOverlay {
    static let shared = MenuBarTintOverlay()
    var alpha: CGFloat = 0.45
    private var panelsByScreenID: [CGDirectDisplayID: NSPanel] = [:]
    private var viewsByScreenID: [CGDirectDisplayID: TintView] = [:]
    private var lastGeometryKey = ""
    private var current: MenuBarTintColor = .off
    private var heightTimer: Timer?

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(forceSync),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        heightTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.syncGeometryIfNeeded()
        }
        if let heightTimer { RunLoop.main.add(heightTimer, forMode: .common) }
        syncGeometryIfNeeded(force: true)
    }

    func stop() {
        heightTimer?.invalidate()
        heightTimer = nil
        apply(.off)
        panelsByScreenID.values.forEach { $0.orderOut(nil) }
        panelsByScreenID.removeAll()
        viewsByScreenID.removeAll()
        lastGeometryKey = ""
    }

    func apply(_ color: MenuBarTintColor) {
        current = color
        syncGeometryIfNeeded(force: panelsByScreenID.isEmpty)
        let fill = fillColor(for: color)
        viewsByScreenID.values.forEach { $0.fillColor = fill }
        // Always keep panels ordered front (even when clear) so AppKit doesn't
        // auto-terminate the accessory process for "no windows open".
        panelsByScreenID.values.forEach { $0.orderFrontRegardless() }
        fputs("tint=\(color)\n", stderr)
    }

    private func fillColor(for color: MenuBarTintColor) -> NSColor {
        switch color {
        case .off: return .clear
        case .orange: return NSColor.systemOrange.withAlphaComponent(alpha)
        case .green: return NSColor.systemGreen.withAlphaComponent(alpha)
        }
    }

    private var level: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
    }

    @objc private func forceSync() { syncGeometryIfNeeded(force: true) }

    private func syncGeometryIfNeeded(force: Bool = false) {
        var bands: [(CGDirectDisplayID, NSRect, CGFloat)] = []
        for screen in NSScreen.screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            let barH = frame.maxY - visible.maxY
            // Per screen: only paint where macOS currently reserves a menu bar.
            guard barH > 0.5 else { continue }
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let rect = NSRect(x: frame.minX, y: frame.maxY - barH, width: frame.width, height: barH)
            bands.append((id, rect, barH))
        }
        let key = bands.map { id, r, h in
            String(format: "%u:%.1f,%.1f,%.1fx%.1f", id, r.minX, r.minY, r.width, h)
        }.joined(separator: "|")
        guard force || key != lastGeometryKey else { return }
        lastGeometryKey = key

        let active = Set(bands.map(\.0))
        for (id, panel) in panelsByScreenID where !active.contains(id) {
            panel.orderOut(nil)
            panelsByScreenID.removeValue(forKey: id)
            viewsByScreenID.removeValue(forKey: id)
        }

        let fill = fillColor(for: current)
        for (id, rect, barH) in bands {
            fputs(String(format: "menubar screen=%u height=%.1f\n", id, barH), stderr)
            if let panel = panelsByScreenID[id] {
                panel.setFrame(rect, display: true)
                viewsByScreenID[id]?.frame = NSRect(origin: .zero, size: rect.size)
                viewsByScreenID[id]?.fillColor = fill
                panel.orderFrontRegardless()
                continue
            }
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
            view.fillColor = fill
            panel.contentView = view
            panelsByScreenID[id] = panel
            viewsByScreenID[id] = view
            panel.orderFrontRegardless()
        }
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
    private var pollTimer: Timer?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("live-tint")
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "menu-bar mic/camera tint"
        )

        MenuBarTintOverlay.shared.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎙"
        item.button?.toolTip = "live-tint — mic→orange, cam→green"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Flash test (orange)", action: #selector(flashTest), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Quit live-tint", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        NotificationCenter.default.addObserver(self, selector: #selector(devConnected(_:)), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(devDisconnected(_:)), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)

        discover()
        refreshTint()

        // Listeners can miss transitions; poll as a safety net.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshTint()
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }

        // Brief visible flash so you know the overlay is alive.
        MenuBarTintOverlay.shared.apply(.orange)
        statusItem?.button?.title = "🟠"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshTint()
        }

        fputs("live-tint running — flash orange 1.5s, then mic/cam. Menu: Flash test / Quit.\n", stderr)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        MenuBarTintOverlay.shared.stop()
        monitors.values.forEach { $0.stopMonitoring() }
        monitors.removeAll()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func flashTest() {
        MenuBarTintOverlay.shared.apply(.orange)
        statusItem?.button?.title = "🟠"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshTint()
        }
    }

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

    private var lastReported: MenuBarTintColor = .off

    private func refreshTint() {
        var mic = false, cam = false
        var activeNames: [String] = []
        for m in monitors.values where m.queryIsRunning() {
            if m.isVideo { cam = true } else { mic = true }
            activeNames.append(m.device.localizedName)
        }
        let next: MenuBarTintColor
        if cam {
            next = .green
            statusItem?.button?.title = "🟢"
        } else if mic {
            next = .orange
            statusItem?.button?.title = "🟠"
        } else {
            next = .off
            statusItem?.button?.title = "🎙"
        }
        if next != lastReported {
            lastReported = next
            if !activeNames.isEmpty {
                fputs("active: \(activeNames.joined(separator: ", "))\n", stderr)
            }
        }
        MenuBarTintOverlay.shared.apply(next)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
