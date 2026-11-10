import AppKit
import AVFoundation
import CoreAudio
import CoreMediaIO
import CoreGraphics

// Expandable mic-level menu bar (plan: mic_input_activity_tint).
// Build:
//   swiftc -O -framework AppKit -framework AVFoundation -framework CoreAudio \
//     -framework CoreMediaIO -framework CoreGraphics \
//     -o live-tint MicLevelMonitor.swift main.swift
// Quit: status menu → Quit

enum OverlayBackground {
    case clear
    case orange // mic open
    case green  // camera on (wins backdrop)
}

/// Height is dynamic + per-screen: frame.maxY - visibleFrame.maxY.
final class MenuBarTintOverlay {
    static let shared = MenuBarTintOverlay()

    var backgroundAlpha: CGFloat = 0.40
    var meterAlpha: CGFloat = 0.85
    var stubWidth: CGFloat = 32
    /// Max meter width as a fraction of the bar.
    var maxMeterFraction: CGFloat = 0.70
    /// Curve on level so quiet speech still moves the bar a bit.
    var levelCurve: CGFloat = 0.65

    private var panelsByScreenID: [CGDirectDisplayID: NSPanel] = [:]
    private var viewsByScreenID: [CGDirectDisplayID: MeterBarView] = [:]
    private var lastGeometryKey = ""
    private var background: OverlayBackground = .clear
    private var showMeter = false
    private var level: CGFloat = 0
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
        apply(background: .clear, showMeter: false, level: 0)
        panelsByScreenID.values.forEach { $0.orderOut(nil) }
        panelsByScreenID.removeAll()
        viewsByScreenID.removeAll()
        lastGeometryKey = ""
    }

    func apply(background: OverlayBackground, showMeter: Bool, level: CGFloat) {
        self.background = background
        self.showMeter = showMeter
        self.level = max(0, min(1, level))
        syncGeometryIfNeeded(force: panelsByScreenID.isEmpty)
        pushVisuals()
        panelsByScreenID.values.forEach { $0.orderFrontRegardless() }
    }

    func setLevel(_ level: CGFloat) {
        self.level = max(0, min(1, level))
        for view in viewsByScreenID.values {
            view.level = self.level
        }
    }

    private func pushVisuals() {
        let bg = backgroundColor()
        for view in viewsByScreenID.values {
            view.backgroundFill = bg
            view.showMeter = showMeter
            view.level = level
            view.stubWidth = stubWidth
            view.maxMeterFraction = maxMeterFraction
            view.levelCurve = levelCurve
            view.meterFill = NSColor.systemRed.withAlphaComponent(meterAlpha)
        }
    }

    private func backgroundColor() -> NSColor {
        switch background {
        case .clear: return .clear
        case .orange: return NSColor.systemOrange.withAlphaComponent(backgroundAlpha)
        case .green: return NSColor.systemGreen.withAlphaComponent(backgroundAlpha)
        }
    }

    private var windowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
    }

    @objc private func forceSync() { syncGeometryIfNeeded(force: true) }

    private func syncGeometryIfNeeded(force: Bool = false) {
        var bands: [(CGDirectDisplayID, NSRect, CGFloat)] = []
        for screen in NSScreen.screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            let barH = frame.maxY - visible.maxY
            guard barH > 0.5 else { continue }
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let rect = NSRect(x: frame.minX, y: frame.maxY - barH, width: frame.width, height: barH)
            bands.append((id, rect, barH))
        }
        let key = bands.map { id, r, h in
            String(format: "%u:%.1f,%.1f,%.1fx%.1f", id, r.minX, r.minY, r.width, h)
        }.joined(separator: "|")
        guard force || key != lastGeometryKey else {
            pushVisuals()
            return
        }
        lastGeometryKey = key

        let active = Set(bands.map(\.0))
        for (id, panel) in panelsByScreenID where !active.contains(id) {
            panel.orderOut(nil)
            panelsByScreenID.removeValue(forKey: id)
            viewsByScreenID.removeValue(forKey: id)
        }

        for (id, rect, barH) in bands {
            fputs(String(format: "menubar screen=%u height=%.1f\n", id, barH), stderr)
            if let panel = panelsByScreenID[id] {
                panel.setFrame(rect, display: true)
                viewsByScreenID[id]?.frame = NSRect(origin: .zero, size: rect.size)
                panel.orderFrontRegardless()
                continue
            }
            let panel = NSPanel(
                contentRect: rect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.setFrame(rect, display: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = windowLevel
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            let view = MeterBarView(frame: NSRect(origin: .zero, size: rect.size))
            panel.contentView = view
            panelsByScreenID[id] = panel
            viewsByScreenID[id] = view
            panel.orderFrontRegardless()
        }
        pushVisuals()
    }
}

/// Full-width background + centered red meter that expands with level.
final class MeterBarView: NSView {
    var backgroundFill: NSColor = .clear { didSet { needsDisplay = true } }
    var meterFill: NSColor = NSColor.systemRed.withAlphaComponent(0.85) { didSet { needsDisplay = true } }
    var showMeter = false { didSet { needsDisplay = true } }
    var level: CGFloat = 0 { didSet { needsDisplay = true } }
    var stubWidth: CGFloat = 32
    var maxMeterFraction: CGFloat = 0.70
    var levelCurve: CGFloat = 0.65

    override func draw(_ dirtyRect: NSRect) {
        backgroundFill.setFill()
        bounds.fill()

        guard showMeter else { return }
        let barW = bounds.width
        let maxW = barW * maxMeterFraction
        let curved = pow(max(0, min(1, level)), levelCurve)
        let meterW = min(maxW, stubWidth + (maxW - stubWidth) * curved)
        let x = (barW - meterW) * 0.5
        let meterRect = NSRect(x: x, y: 0, width: meterW, height: bounds.height)
        meterFill.setFill()
        meterRect.fill()
    }

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
    private var lastMic = false
    private var lastCam = false
    private var lastLevelBucket = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("live-tint")
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "menu-bar mic/camera level tint"
        )

        MenuBarTintOverlay.shared.start()
        MicLevelMonitor.shared.onLevel = { [weak self] level in
            MenuBarTintOverlay.shared.setLevel(CGFloat(level))
            self?.updateStatusLevel(level)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎙"
        item.button?.toolTip = "live-tint — orange=mic, green=cam, red=level"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Flash test (orange + stub)", action: #selector(flashTest), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Quit live-tint", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        NotificationCenter.default.addObserver(self, selector: #selector(devConnected(_:)), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(devDisconnected(_:)), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)

        discover()
        refreshState()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }

        // Brief sanity flash.
        MenuBarTintOverlay.shared.apply(background: .orange, showMeter: true, level: 0)
        statusItem?.button?.title = "🟠"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refreshState()
        }

        fputs("live-tint: orange=mic open, green=cam, red stub/expand=level\n", stderr)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        MicLevelMonitor.shared.setActive(false)
        MenuBarTintOverlay.shared.stop()
        monitors.values.forEach { $0.stopMonitoring() }
        monitors.removeAll()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func flashTest() {
        MenuBarTintOverlay.shared.apply(background: .orange, showMeter: true, level: 0)
        statusItem?.button?.title = "🟠"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refreshState()
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
            self?.refreshState()
        }) else { return }
        monitors[device.uniqueID] = m
        m.startMonitoring()
        fputs("watch \(device.hasMediaType(.video) ? "cam" : "mic"): \(device.localizedName)\n", stderr)
    }

    @objc private func devConnected(_ note: Notification) {
        if let d = note.object as? AVCaptureDevice { monitor(d); refreshState() }
    }

    @objc private func devDisconnected(_ note: Notification) {
        if let d = note.object as? AVCaptureDevice {
            monitors[d.uniqueID]?.stopMonitoring()
            monitors.removeValue(forKey: d.uniqueID)
            refreshState()
        }
    }

    private func refreshState() {
        var mic = false, cam = false
        for m in monitors.values where m.queryIsRunning() {
            if m.isVideo { cam = true } else { mic = true }
        }

        MicLevelMonitor.shared.setActive(mic)

        let bg: OverlayBackground
        if cam {
            bg = .green
            statusItem?.button?.title = mic ? "🟢🎙" : "🟢"
        } else if mic {
            bg = .orange
            statusItem?.button?.title = "🟠"
        } else {
            bg = .clear
            statusItem?.button?.title = "🎙"
        }

        let level = CGFloat(MicLevelMonitor.shared.level)
        MenuBarTintOverlay.shared.apply(background: bg, showMeter: mic, level: level)

        if mic != lastMic || cam != lastCam {
            lastMic = mic
            lastCam = cam
            fputs("state mic=\(mic) cam=\(cam)\n", stderr)
        }
    }

    private func updateStatusLevel(_ level: Float) {
        let bucket = Int(level * 10)
        guard bucket != lastLevelBucket else { return }
        lastLevelBucket = bucket
        if lastMic {
            fputs(String(format: "level=%.2f\n", level), stderr)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
