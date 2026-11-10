import AppKit
import CoreGraphics

/// Semi-transparent click-through strip over the menu bar.
/// Height is **dynamic and per-screen**: `screen.frame.maxY - screen.visibleFrame.maxY`
/// (the live menu-bar band macOS reserves). Re-measured on screen changes and on a short timer
/// so auto-hide / fullscreen / resolution shifts track without a fixed drip.
enum MenuBarTintColor {
    case off
    case orange // microphone
    case green  // camera (or both)
}

final class MenuBarTintOverlay {
    static let shared = MenuBarTintOverlay()

    var alpha: CGFloat = 0.45
    var isEnabled: Bool = true {
        didSet { apply(current) }
    }

    private var panelsByScreenID: [CGDirectDisplayID: NSPanel] = [:]
    private var viewsByScreenID: [CGDirectDisplayID: TintView] = [:]
    private var lastGeometryKey: String = ""
    private var current: MenuBarTintColor = .off
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
        // visibleFrame often changes (menu bar auto-hide, fullscreen) without a screen-params ping.
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
        apply(.off)
        panelsByScreenID.values.forEach { $0.orderOut(nil) }
        panelsByScreenID.removeAll()
        viewsByScreenID.removeAll()
        lastGeometryKey = ""
        started = false
    }

    func apply(_ color: MenuBarTintColor) {
        current = color
        syncGeometryIfNeeded()
        let fill = fillColor(for: color)
        for view in viewsByScreenID.values {
            view.fillColor = fill
        }
        if color != .off && isEnabled {
            panelsByScreenID.values.forEach { $0.orderFrontRegardless() }
        }
    }

    private func fillColor(for color: MenuBarTintColor) -> NSColor {
        guard isEnabled else { return .clear }
        switch color {
        case .off: return .clear
        case .orange: return NSColor.systemOrange.withAlphaComponent(alpha)
        case .green: return NSColor.systemGreen.withAlphaComponent(alpha)
        }
    }

    private var overlayLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
    }

    @objc private func geometryMayHaveChanged() {
        syncGeometryIfNeeded(force: true)
    }

    /// Snapshot of per-screen menu-bar rectangles derived from AppKit's live layout.
    private func currentMenuBarBands() -> [(CGDirectDisplayID, NSRect, CGFloat)] {
        var bands: [(CGDirectDisplayID, NSRect, CGFloat)] = []
        for screen in NSScreen.screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            // Per-screen menu bar height reserved by the system right now.
            let barHeight = frame.maxY - visible.maxY
            guard barHeight > 0.5 else {
                // No menu bar on this display (often secondary when "menu bar on main only",
                // or temporarily hidden). Skip — do not invent a fake height.
                continue
            }
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                ?? 0
            let rect = NSRect(
                x: frame.minX,
                y: frame.maxY - barHeight,
                width: frame.width,
                height: barHeight
            )
            bands.append((displayID, rect, barHeight))
        }
        return bands
    }

    private func geometryKey(for bands: [(CGDirectDisplayID, NSRect, CGFloat)]) -> String {
        bands
            .map { id, rect, h in
                String(format: "%u:%.1f,%.1f,%.1f,%.1f@%.1f", id, rect.minX, rect.minY, rect.width, rect.height, h)
            }
            .joined(separator: "|")
    }

    private func syncGeometryIfNeeded(force: Bool = false) {
        let bands = currentMenuBarBands()
        let key = geometryKey(for: bands)
        guard force || key != lastGeometryKey else { return }
        lastGeometryKey = key

        let activeIDs = Set(bands.map(\.0))
        for (id, panel) in panelsByScreenID where !activeIDs.contains(id) {
            panel.orderOut(nil)
            panelsByScreenID.removeValue(forKey: id)
            viewsByScreenID.removeValue(forKey: id)
        }

        let fill = fillColor(for: current)
        for (displayID, rect, barHeight) in bands {
            fputs(String(format: "menubar screen=%u height=%.1f rect=%@\n", displayID, barHeight, NSStringFromRect(rect)), stderr)

            if let panel = panelsByScreenID[displayID] {
                panel.setFrame(rect, display: true)
                viewsByScreenID[displayID]?.frame = NSRect(origin: .zero, size: rect.size)
                viewsByScreenID[displayID]?.fillColor = fill
                if current != .off && isEnabled {
                    panel.orderFrontRegardless()
                }
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

            let view = TintView(frame: NSRect(origin: .zero, size: rect.size))
            view.fillColor = fill
            panel.contentView = view
            panelsByScreenID[displayID] = panel
            viewsByScreenID[displayID] = view
            if current != .off && isEnabled {
                panel.orderFrontRegardless()
            }
        }
    }
}

private final class TintView: NSView {
    var fillColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        bounds.fill()
    }

    override var acceptsFirstResponder: Bool { false }
}
