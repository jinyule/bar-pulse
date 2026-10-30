import AppKit

/// The dashboard window. It hangs below the status item like a menu: borderless and rounded, on a
/// frosted background whose opacity the user picks, and resizable by dragging its left, right or
/// bottom edge or a bottom corner. The top edge stays attached under the menu bar.
@MainActor
final class DashboardPanel: NSPanel {
    static let cornerRadius: CGFloat = 20
    private static let menuBarGap: CGFloat = 5
    private static let screenMargin: CGFloat = 8

    /// Smallest size the content can lay out in.
    var minimumSize = CGSize(width: 320, height: 240)
    /// The content's natural size, used until the user resizes the panel.
    var idealSize = CGSize(width: 660, height: 840)
    /// The size asked for by the last `place` call (before clamping to the screen).
    private(set) var requestedSize: CGSize?
    /// Called once a resize drag ends, with the new size.
    var onResize: ((CGSize) -> Void)?
    /// Called when the user presses Escape.
    var onCancel: (() -> Void)?

    private let content: NSViewController
    private let background = DashboardPanel.makeBackground()

    init(content: NSViewController) {
        self.content = content
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        setAccessibilityTitle("BarPulse 仪表盘")

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        root.wantsLayer = true
        root.layer?.cornerRadius = Self.cornerRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        for view in [background, content.view] {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        for edges in ResizeHandle.placements {
            root.addSubview(ResizeHandle(edges: edges, in: root.bounds))
        }
        root.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: self))
        contentView = root
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // The panel opens without taking keyboard focus, so typing elsewhere carries on. It takes
    // focus once the pointer comes over it: only the key window gets its cursors (the resize
    // arrows), hover effects and Escape, since the app itself stays in the background.
    override func mouseEntered(with event: NSEvent) {
        if !isKeyWindow { makeKey() }
    }

    override func sendEvent(_ event: NSEvent) {
        // Clicks can arrive without the pointer entering first (e.g. posted to the app directly);
        // take focus before the click is dispatched, so it already reaches the control under it.
        if event.type == .leftMouseDown && !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Opacity of the frosted background; the SwiftUI cards fade separately.
    var backgroundOpacity: CGFloat {
        get { background.alphaValue }
        set {
            guard abs(background.alphaValue - newValue) > 0.001 else { return }
            background.alphaValue = newValue
            invalidateShadow()
        }
    }

    // MARK: - Placement

    /// Sizes the panel and hangs it below `anchor`, the status item's frame in screen coordinates.
    func place(below anchor: NSRect, on screen: NSScreen, size: CGSize) {
        requestedSize = size
        let area = screen.visibleFrame
        // The menu bar may auto-hide, so prefer the item's own bottom edge when it's on this screen.
        let anchored = screen.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY))
        let top = (anchored ? min(area.maxY, anchor.minY) : area.maxY) - Self.menuBarGap
        let bounds = area.insetBy(dx: Self.screenMargin, dy: 0)
        let width = clamp(size.width.rounded(), minimumSize.width, bounds.width)
        let height = clamp(size.height.rounded(), minimumSize.height, top - area.minY - Self.screenMargin)
        let midX = anchored ? anchor.midX : bounds.maxX - width / 2
        let x = clamp((midX - width / 2).rounded(), bounds.minX, bounds.maxX - width)
        setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        invalidateShadow()
    }

    /// Shows the panel without activating the app or taking keyboard focus, so whatever the user
    /// is typing into keeps it (see `mouseEntered` for when the panel does take focus).
    func present() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [self] in
            MainActor.assumeIsolated {
                orderOut(nil)
                // Drop the SwiftUI tree right away rather than whenever the panel is released.
                contentView = nil
            }
        })
    }

    // MARK: - Resizing

    fileprivate func resize(_ edges: ResizeHandle.Edges, from start: NSRect, by delta: CGPoint) {
        guard let area = screen?.visibleFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin) else { return }
        var frame = start
        if edges.contains(.left) {
            frame.size.width = clamp((start.width - delta.x).rounded(), minimumSize.width, start.maxX - area.minX)
            frame.origin.x = start.maxX - frame.width
        }
        if edges.contains(.right) {
            frame.size.width = clamp((start.width + delta.x).rounded(), minimumSize.width, area.maxX - start.minX)
        }
        if edges.contains(.bottom) {
            frame.size.height = clamp((start.height - delta.y).rounded(), minimumSize.height, start.maxY - area.minY)
            frame.origin.y = start.maxY - frame.height
        }
        guard frame != self.frame else { return }
        setFrame(frame, display: true)
        invalidateShadow()
    }

    fileprivate func endResize() {
        requestedSize = frame.size
        onResize?(frame.size)
    }

    private static func makeBackground() -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }
}

private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    // The lower bound wins when the screen is too small for the content.
    max(lower, min(value, upper))
}

/// An invisible strip along a resizable edge (or a square at a bottom corner) that shows the
/// resize cursor and turns drags into frame changes. Mouse positions are taken in screen
/// coordinates because the view itself moves while its window resizes.
private final class ResizeHandle: NSView {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
    }

    static let placements: [Edges] = [.left, .right, .bottom, [.bottom, .left], [.bottom, .right]]
    private static let thickness: CGFloat = 6
    /// Corners are larger, since the panel's rounded corner clips part of the square.
    private static let corner: CGFloat = 22

    let edges: Edges
    private var start: (frame: NSRect, mouse: NSPoint)?

    init(edges: Edges, in bounds: NSRect) {
        self.edges = edges
        let t = Self.thickness, c = Self.corner
        let frame: NSRect
        var mask: NSView.AutoresizingMask
        switch edges {
        case .left:
            frame = NSRect(x: 0, y: c, width: t, height: bounds.height - c)
            mask = [.height, .maxXMargin]
        case .right:
            frame = NSRect(x: bounds.width - t, y: c, width: t, height: bounds.height - c)
            mask = [.height, .minXMargin]
        case .bottom:
            frame = NSRect(x: c, y: 0, width: bounds.width - 2 * c, height: t)
            mask = [.width, .maxYMargin]
        case [.bottom, .left]:
            frame = NSRect(x: 0, y: 0, width: c, height: c)
            mask = [.maxXMargin, .maxYMargin]
        default:
            frame = NSRect(x: bounds.width - c, y: 0, width: c, height: c)
            mask = [.minXMargin, .maxYMargin]
        }
        super.init(frame: frame)
        autoresizingMask = mask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch edges {
            case .left: .left
            case .right: .right
            case .bottom: .bottom
            case [.bottom, .left]: .bottomLeft
            default: .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        return edges == .bottom ? .resizeUpDown : .resizeLeftRight
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Cursor rects only work in an active app; the panel may be key without activating it.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        if start == nil { NSCursor.arrow.set() }
    }

    /// Where the event happened in screen coordinates. Taken from the event itself rather than the
    /// pointer, which also makes drags work when they're posted to the app directly.
    private func screenLocation(of event: NSEvent) -> NSPoint {
        guard let location = event.cgEvent?.location, let primary = NSScreen.screens.first else { return NSEvent.mouseLocation }
        return NSPoint(x: location.x, y: primary.frame.maxY - location.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = (window.frame, screenLocation(of: event))
        cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let panel = window as? DashboardPanel else { return }
        let mouse = screenLocation(of: event)
        panel.resize(edges, from: start.frame, by: CGPoint(x: mouse.x - start.mouse.x, y: mouse.y - start.mouse.y))
        cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        (window as? DashboardPanel)?.endResize()
        if !NSMouseInRect(convert(event.locationInWindow, from: nil), bounds, isFlipped) {
            NSCursor.arrow.set()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // A small grip in the bottom-right corner hints that the panel can be resized.
        guard edges == [.bottom, .right] else { return }
        let path = NSBezierPath()
        let center = NSPoint(x: bounds.maxX - 10.5, y: 10.5)
        for offset in [-3.0, 0.5] as [CGFloat] {
            let length: CGFloat = offset < 0 ? 4.5 : 2.2
            let base = NSPoint(x: center.x + offset, y: center.y - offset)
            path.move(to: NSPoint(x: base.x - length, y: base.y - length))
            path.line(to: NSPoint(x: base.x + length, y: base.y + length))
        }
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
    }
}
