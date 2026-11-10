import AppKit
import CoreGraphics

/// Semi-transparent click-through strip over the menu bar.
/// Level sits above menu chrome (`mainMenuWindow + 2`); mouse events pass through.
enum MenuBarTintColor {
    case off
    case orange // microphone
    case green  // camera (or both)
}

final class MenuBarTintOverlay {
    static let shared = MenuBarTintOverlay()

    /// Production look: light drip so tint stays visible if the bar material is opaque.
    var dripBelowBar: CGFloat = 8
    var alpha: CGFloat = 0.45
    var isEnabled: Bool = true {
        didSet { apply(current) }
    }

    private var panels: [NSPanel] = []
    private var views: [TintView] = []
    private var current: MenuBarTintColor = .off
    private var observingScreens = false

    private init() {}

    func start() {
        guard !observingScreens else { return }
        observingScreens = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildPanels),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        rebuildPanels()
    }

    func stop() {
        apply(.off)
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
    }

    func apply(_ color: MenuBarTintColor) {
        current = color
        if panels.isEmpty { rebuildPanels() }
        let fill: NSColor
        if !isEnabled {
            fill = .clear
        } else {
            switch color {
            case .off:
                fill = .clear
            case .orange:
                fill = NSColor.systemOrange.withAlphaComponent(alpha)
            case .green:
                fill = NSColor.systemGreen.withAlphaComponent(alpha)
            }
        }
        for view in views {
            view.fillColor = fill
        }
        if color != .off && isEnabled {
            panels.forEach { $0.orderFrontRegardless() }
        }
    }

    private var overlayLevel: NSWindow.Level {
        let mainMenu = CGWindowLevelForKey(.mainMenuWindow)
        return NSWindow.Level(rawValue: Int(mainMenu) + 2)
    }

    @objc private func rebuildPanels() {
        let previous = current
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()

        for screen in NSScreen.screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            var barHeight = frame.maxY - visible.maxY
            if barHeight < 1 {
                barHeight = max(screen.safeAreaInsets.top, 28)
            }
            let totalHeight = barHeight + dripBelowBar
            let rect = NSRect(
                x: frame.minX,
                y: frame.maxY - totalHeight,
                width: frame.width,
                height: totalHeight
            )

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
            panel.contentView = view
            panels.append(panel)
            views.append(view)
            panel.orderFrontRegardless()
        }
        apply(previous)
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
