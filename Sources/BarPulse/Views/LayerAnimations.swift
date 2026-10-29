import AppKit
import SwiftUI

// SwiftUI re-rasterizes animated content on the CPU every frame (120 times a second on
// ProMotion displays). These small views animate plain Core Animation layers instead, so the
// render server does the work and the app stays idle between samples.

private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// An SF Symbol that spins continuously while `spinning` is true.
struct SpinningSymbol: NSViewRepresentable {
    let systemName: String
    let pointSize: CGFloat
    let color: NSColor
    let spinning: Bool

    func makeNSView(context: Context) -> SpinningSymbolView { SpinningSymbolView() }

    func updateNSView(_ view: SpinningSymbolView, context: Context) {
        view.update(systemName: systemName, pointSize: pointSize, color: color, spinning: spinning)
    }
}

final class SpinningSymbolView: NSView {
    private static let spinKey = "spin"
    private let symbolLayer = CALayer()
    private var systemName = ""
    private var pointSize: CGFloat = 0
    private var color = NSColor.labelColor
    private var spinning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(symbolLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(systemName: String, pointSize: CGFloat, color: NSColor, spinning: Bool) {
        if systemName != self.systemName || pointSize != self.pointSize || color != self.color {
            self.systemName = systemName
            self.pointSize = pointSize
            self.color = color
            renderSymbol()
        }
        if spinning != self.spinning {
            self.spinning = spinning
            updateSpin()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderSymbol()
        updateSpin()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderSymbol()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderSymbol()
    }

    private func renderSymbol() {
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = base.withSymbolConfiguration(configuration) ?? base
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var rendered: (image: CGImage, inkCenter: CGPoint)?
        // Resolves dynamic colors such as secondaryLabelColor for this view's appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rendered = Self.rasterize(image, scale: scale)
        }
        guard let rendered else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.contents = rendered.image
        symbolLayer.contentsScale = scale
        symbolLayer.bounds = CGRect(origin: .zero, size: image.size)
        // Symbol images carry uneven padding; spinning around the image centre would wobble.
        symbolLayer.anchorPoint = rendered.inkCenter
        symbolLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    private func updateSpin() {
        guard spinning, window != nil, !reduceMotion else {
            symbolLayer.removeAnimation(forKey: Self.spinKey)
            return
        }
        guard symbolLayer.animation(forKey: Self.spinKey) == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1.4
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        symbolLayer.add(spin, forKey: Self.spinKey)
    }

    /// Draws the image into a bitmap and finds the centre of its visible pixels, as a unit
    /// point in layer coordinates (origin bottom-left).
    private static func rasterize(_ image: NSImage, scale: CGFloat) -> (image: CGImage, inkCenter: CGPoint)? {
        let size = image.size
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage, let pixels = bitmap.bitmapData else { return nil }

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = pixels + y * bitmap.bytesPerRow
            for x in 0..<width where row[x * 4 + 3] > 24 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return (cgImage, CGPoint(x: 0.5, y: 0.5)) }
        // Bitmap rows run top-down; layer unit coordinates run bottom-up.
        let center = CGPoint(x: CGFloat(minX + maxX + 1) / 2 / CGFloat(width),
                             y: 1 - CGFloat(minY + maxY + 1) / 2 / CGFloat(height))
        return (cgImage, center)
    }
}

/// A dot that sends out one ripple per sample: the "live" cue in the dashboard footer.
struct LiveDot: View {
    let tick: Int

    var body: some View {
        PulseDot(tick: tick, color: Theme.memory)
            .frame(width: 12, height: 12)
    }
}

private struct PulseDot: NSViewRepresentable {
    let tick: Int
    let color: NSColor

    func makeNSView(context: Context) -> PulseDotView { PulseDotView(color: color) }

    func updateNSView(_ view: PulseDotView, context: Context) { view.beat(tick) }
}

final class PulseDotView: NSView {
    private let ring = CALayer()
    private let dot = CALayer()
    private var lastTick: Int?

    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        ring.backgroundColor = color.withAlphaComponent(0.45).cgColor
        ring.opacity = 0
        dot.backgroundColor = color.cgColor
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = min(bounds.width, bounds.height)
        ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ring.cornerRadius = side / 2
        ring.position = center
        dot.bounds = CGRect(x: 0, y: 0, width: side / 2, height: side / 2)
        dot.cornerRadius = side / 4
        dot.position = center
        CATransaction.commit()
    }

    func beat(_ tick: Int) {
        defer { lastTick = tick }
        guard let lastTick, tick != lastTick, window != nil, !reduceMotion else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let ripple = CAAnimationGroup()
        ripple.animations = [grow, fade]
        ripple.duration = 0.7
        ripple.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(ripple, forKey: "ripple")
    }
}
