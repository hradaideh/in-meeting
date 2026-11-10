import AppKit
import CoreGraphics

enum OverlayBackground {
    case clear
    case orange // mic open
    case green  // camera on (wins backdrop)
}

/// Semi-transparent click-through strip over the menu bar.
/// Height is dynamic per-screen (`frame.maxY - visibleFrame.maxY`).
/// Layers: orange/green/clear background + centered red meter (stub when quiet, expands with level).
final class MenuBarTintOverlay {
    static let shared = MenuBarTintOverlay()

    var backgroundAlpha: CGFloat = 0.40
    var meterAlpha: CGFloat = 0.85
    var stubWidth: CGFloat = 32
    var maxMeterFraction: CGFloat = 0.70
    var levelCurve: CGFloat = 0.65

    private var panelsByScreenID: [CGDirectDisplayID: NSPanel] = [:]
    private var viewsByScreenID: [CGDirectDisplayID: MeterBarView] = [:]
    private var lastGeometryKey: String = ""
    private var background: OverlayBackground = .clear
    private var showMeter = false
    private var level: CGFloat = 0
    private var heightTimer: Timer?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(geometryMayHaveChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        heightTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.syncGeometryIfNeeded()
        }
        if let heightTimer {
            RunLoop.main.add(heightTimer, forMode: .common)
        }
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
        started = false
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

    private var overlayLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
    }

    @objc private func geometryMayHaveChanged() {
        syncGeometryIfNeeded(force: true)
    }

    private func syncGeometryIfNeeded(force: Bool = false) {
        var bands: [(CGDirectDisplayID, NSRect, CGFloat)] = []
        for screen in NSScreen.screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            let barHeight = frame.maxY - visible.maxY
            guard barHeight > 0.5 else { continue }
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let rect = NSRect(
                x: frame.minX,
                y: frame.maxY - barHeight,
                width: frame.width,
                height: barHeight
            )
            bands.append((displayID, rect, barHeight))
        }
        let key = bands.map { id, rect, h in
            String(format: "%u:%.1f,%.1f,%.1f,%.1f@%.1f", id, rect.minX, rect.minY, rect.width, rect.height, h)
        }.joined(separator: "|")
        guard force || key != lastGeometryKey else {
            pushVisuals()
            return
        }
        lastGeometryKey = key

        let activeIDs = Set(bands.map(\.0))
        for (id, panel) in panelsByScreenID where !activeIDs.contains(id) {
            panel.orderOut(nil)
            panelsByScreenID.removeValue(forKey: id)
            viewsByScreenID.removeValue(forKey: id)
        }

        for (displayID, rect, _) in bands {
            if let panel = panelsByScreenID[displayID] {
                panel.setFrame(rect, display: true)
                viewsByScreenID[displayID]?.frame = NSRect(origin: .zero, size: rect.size)
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
            panel.level = overlayLevel
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .ignoresCycle,
                .fullScreenAuxiliary,
            ]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false

            let view = MeterBarView(frame: NSRect(origin: .zero, size: rect.size))
            panel.contentView = view
            panelsByScreenID[displayID] = panel
            viewsByScreenID[displayID] = view
            panel.orderFrontRegardless()
        }
        pushVisuals()
    }
}

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
