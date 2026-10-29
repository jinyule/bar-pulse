import AppKit
import BarPulseCore

struct StatusBarModel: Equatable {
    var metrics: [Metric] = Metric.allCases
    var layout: AppSettings.Layout = .stacked
    var colorful = true
    var unit: TemperatureUnit = .celsius
    var cpu: Double = 0
    var gpu: Double = 0
    var memory: Double = 0
    var pressure: MemoryPressure = .normal
    var download: Double = 0
    var upload: Double = 0
    var temperature: Double?
}

/// Draws the live readouts inside the status item button.
///
/// Drawing happens in `draw(_:)` with the button's effective appearance, so semantic colors
/// follow the menu bar (light / dark / tinted wallpaper) automatically.
final class StatusBarView: NSView {
    var model = StatusBarModel() {
        didSet {
            guard model != oldValue else { return }
            if model.metrics != oldValue.metrics || model.layout != oldValue.layout || model.unit != oldValue.unit {
                invalidateIntrinsicContentSize()
            }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    // Clicks belong to the status bar button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: StatusBarRenderer(model: model, height: 22, scale: 2).measure(), height: NSView.noIntrinsicMetric)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            StatusBarRenderer(model: model, height: bounds.height, scale: scale).draw()
        }
    }
}

/// Measures and draws the menu bar modules. Widths depend only on fixed templates,
/// never on live values, so the status item does not jitter as numbers change.
struct StatusBarRenderer {
    let model: StatusBarModel
    let height: CGFloat
    let scale: CGFloat

    private static let edgePadding: CGFloat = 3
    private static let captionFont = NSFont.systemFont(ofSize: 8, weight: .bold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    private static let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    private static let unitFont = NSFont.systemFont(ofSize: 7, weight: .bold)
    private static let inlineFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let rateUnits = ["KB/s", "MB/s", "GB/s"]
    /// `secondaryLabelColor` only reads well with vibrancy blending, which custom drawing
    /// in the menu bar doesn't get; a translucent label color stays legible on any wallpaper.
    /// Computed (not stored) because `withAlphaComponent` resolves against the current
    /// drawing appearance, which is only correct inside `draw(_:)`.
    private var secondaryInk: NSColor { NSColor.labelColor.withAlphaComponent(0.66) }

    private var spacing: CGFloat { model.layout == .stacked ? 10 : 9 }

    func measure() -> CGFloat { run(draw: false) }

    func draw() { _ = run(draw: true) }

    private func run(draw: Bool) -> CGFloat {
        var x = Self.edgePadding
        for (index, metric) in model.metrics.enumerated() {
            if index > 0 { x += spacing }
            x += module(metric, x: x, draw: draw)
        }
        return ceil(x + Self.edgePadding)
    }

    // MARK: - Modules

    private func module(_ metric: Metric, x: CGFloat, draw: Bool) -> CGFloat {
        switch metric {
        case .cpu:
            return gauge(metric, value: Format.percent(model.cpu), template: "100%", fraction: model.cpu,
                         tint: tint(Theme.cpu), x: x, draw: draw)
        case .gpu:
            return gauge(metric, value: Format.percent(model.gpu), template: "100%", fraction: model.gpu,
                         tint: tint(Theme.gpu), x: x, draw: draw)
        case .memory:
            return gauge(metric, value: Format.percent(model.memory), template: "100%", fraction: model.memory,
                         tint: tint(memoryColor), x: x, draw: draw)
        case .temperature:
            let celsius = model.temperature
            let template = model.unit == .celsius ? "88°" : "188°"
            return gauge(metric, value: Format.temperature(celsius, unit: model.unit), template: template,
                         fraction: celsius.map(Theme.heatFraction) ?? 0,
                         tint: temperatureTint(celsius), x: x, draw: draw)
        case .network:
            return model.layout == .stacked ? stackedNetwork(x: x, draw: draw) : inlineNetwork(x: x, draw: draw)
        }
    }

    private var memoryColor: NSColor {
        switch model.pressure {
        case .normal: return Theme.memory
        case .warning: return Theme.wired
        case .critical: return .systemRed
        }
    }

    private func tint(_ color: NSColor) -> NSColor {
        model.colorful ? color : .labelColor
    }

    /// Heat is signalled by the bar only: coloured digits lose too much contrast on a tinted menu bar.
    /// Monochrome mode still turns the bar warm once things get hot.
    private func temperatureTint(_ celsius: Double?) -> NSColor {
        guard let celsius else { return tint(Theme.thermal) }
        return model.colorful || celsius >= 80 ? Theme.heat(celsius) : .labelColor
    }

    private func gauge(_ metric: Metric, value: String, template: String, fraction: Double, tint: NSColor,
                       x: CGFloat, draw: Bool) -> CGFloat {
        if model.layout == .inline {
            return inlineGauge(metric, value: value, template: template, tint: tint, x: x, draw: draw)
        }
        let barWidth: CGFloat = 3.5
        let gap: CGFloat = 4
        let textWidth = max(Self.width(metric.caption, captionAttributes(secondaryInk)),
                            Self.width(template, [.font: Self.valueFont]))
        let total = barWidth + gap + ceil(textWidth)
        guard draw else { return total }

        let captionCap = Self.captionFont.capHeight
        let valueCap = Self.valueFont.capHeight
        let block = captionCap + 3 + valueCap
        let top = snap((height - block) / 2)
        let captionBaseline = snap(top + captionCap)
        let valueBaseline = snap(top + block)

        drawBar(NSRect(x: x, y: top - 0.5, width: barWidth, height: valueBaseline - top + 1), fraction: fraction, tint: tint)
        let textX = x + barWidth + gap
        drawText(metric.caption, attributes: captionAttributes(secondaryInk), x: textX, baseline: captionBaseline)
        drawText(value, attributes: [.font: Self.valueFont, .foregroundColor: NSColor.labelColor],
                 x: textX, baseline: valueBaseline)
        return total
    }

    private func inlineGauge(_ metric: Metric, value: String, template: String, tint: NSColor,
                             x: CGFloat, draw: Bool) -> CGFloat {
        let iconSize: CGFloat = 14
        let gap: CGFloat = 3
        let total = iconSize + gap + ceil(Self.width(template, [.font: Self.inlineFont]))
        guard draw else { return total }
        let baseline = snap((height + Self.inlineFont.capHeight) / 2)
        drawSymbol(metric.menuBarSymbol, color: tint, in: NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
        drawText(value, attributes: [.font: Self.inlineFont, .foregroundColor: NSColor.labelColor],
                 x: x + iconSize + gap, baseline: baseline)
        return total
    }

    private func stackedNetwork(x: CGFloat, draw: Bool) -> CGFloat {
        let slots = rateSlots(font: Self.rowFont)
        let total = rateWidth(slots)
        guard draw else { return total }
        let cap = Self.rowFont.capHeight
        let block = cap * 2 + 4
        let top = snap((height - block) / 2)
        drawRate(model.upload, up: true, font: Self.rowFont, slots: slots, x: x, baseline: snap(top + cap))
        drawRate(model.download, up: false, font: Self.rowFont, slots: slots, x: x, baseline: snap(top + block))
        return total
    }

    private func inlineNetwork(x: CGFloat, draw: Bool) -> CGFloat {
        let slots = rateSlots(font: Self.inlineFont)
        let single = rateWidth(slots)
        let gap: CGFloat = 7
        guard draw else { return single * 2 + gap }
        let baseline = snap((height + Self.inlineFont.capHeight) / 2)
        drawRate(model.download, up: false, font: Self.inlineFont, slots: slots, x: x, baseline: baseline)
        drawRate(model.upload, up: true, font: Self.inlineFont, slots: slots, x: x + single + gap, baseline: baseline)
        return single * 2 + gap
    }

    // MARK: - Network pieces

    private struct RateSlots {
        var arrow: CGFloat
        var value: CGFloat
        var unit: CGFloat
    }

    private func rateSlots(font: NSFont) -> RateSlots {
        RateSlots(
            arrow: font.pointSize >= 12 ? 6.5 : 5.5,
            value: ceil(max(Self.width("88.8", [.font: font]), Self.width("888", [.font: font]))),
            unit: ceil(Self.rateUnits.map { Self.width($0, unitAttributes) }.max() ?? 0)
        )
    }

    private func rateWidth(_ slots: RateSlots) -> CGFloat {
        slots.arrow + 3 + slots.value + 2 + slots.unit
    }

    private func drawRate(_ bytesPerSecond: Double, up: Bool, font: NSFont, slots: RateSlots, x: CGFloat, baseline: CGFloat) {
        let parts = Format.rateParts(bytesPerSecond)
        let active = bytesPerSecond >= 2048
        let base = model.colorful ? (up ? Theme.upload : Theme.download) : secondaryInk
        let arrowColor = base.withAlphaComponent(active ? 1 : 0.45)

        let cap = font.capHeight
        let arrowHeight = slots.arrow * 0.86
        let midY = baseline - cap / 2
        drawTriangle(up: up, rect: NSRect(x: x, y: midY - arrowHeight / 2, width: slots.arrow, height: arrowHeight), color: arrowColor)

        let valueAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let valueX = x + slots.arrow + 3 + slots.value - Self.width(parts.value, valueAttributes)
        drawText(parts.value, attributes: valueAttributes, x: valueX, baseline: baseline)
        drawText(parts.unit, attributes: unitAttributes, x: x + slots.arrow + 3 + slots.value + 2, baseline: baseline)
    }

    // MARK: - Primitives

    private var unitAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.unitFont, .foregroundColor: secondaryInk, .kern: 0.2]
    }

    private func captionAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: Self.captionFont, .foregroundColor: color, .kern: 0.6]
    }

    private func drawBar(_ rect: NSRect, fraction: Double, tint: NSColor) {
        let radius = rect.width / 2
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let clamped = CGFloat(min(1, max(0, fraction)))
        guard clamped > 0.004 else { return }
        let fillHeight = max(rect.width, rect.height * clamped)
        let fill = NSRect(x: rect.minX, y: rect.maxY - fillHeight, width: rect.width, height: fillHeight)
        tint.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    private func drawTriangle(up: Bool, rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        if up {
            path.move(to: NSPoint(x: rect.midX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY))
        }
        path.close()
        path.lineJoinStyle = .round
        path.lineWidth = 1
        color.setFill()
        color.setStroke()
        path.fill()
        path.stroke()
    }

    private func drawSymbol(_ name: String, color: NSColor, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let target = NSRect(x: snap(rect.midX - size.width / 2), y: snap(rect.midY - size.height / 2),
                            width: size.width, height: size.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Draws a single line so that its baseline lands exactly on `baseline` (flipped coordinates).
    private func drawText(_ string: String, attributes: [NSAttributedString.Key: Any], x: CGFloat, baseline: CGFloat) {
        guard let font = attributes[.font] as? NSFont else { return }
        NSAttributedString(string: string, attributes: attributes).draw(at: NSPoint(x: x, y: baseline - font.ascender))
    }

    private static func width(_ string: String, _ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        NSAttributedString(string: string, attributes: attributes).size().width
    }

    private func snap(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }
}
