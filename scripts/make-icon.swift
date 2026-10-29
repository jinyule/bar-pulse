// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    // Apple's macOS icon grid: 824pt squircle centred on a 1024 canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    context.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    context.restoreGState()

    context.saveGState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.56, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.40, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.72, green: 0.38, blue: 0.98, alpha: 1),
    ])!.draw(in: tile, angle: -50)

    // Soft top sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)

    // Faint meter bars along the bottom, echoing the menu bar indicators.
    let heights: [CGFloat] = [0.32, 0.55, 0.42, 0.7, 0.5, 0.86, 0.6]
    let barWidth: CGFloat = 54
    let gap: CGFloat = 30
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = tile.midX - totalWidth / 2
    for height in heights {
        let rect = NSRect(x: x, y: 190, width: barWidth, height: 300 * height)
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    // The pulse line.
    let pulse = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [(210, 520), (370, 520), (430, 640), (505, 330), (585, 720), (650, 470), (690, 520), (814, 520)]
    pulse.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for point in points.dropFirst() { pulse.line(to: NSPoint(x: point.0, y: point.1)) }
    pulse.lineWidth = 58
    pulse.lineCapStyle = .round
    pulse.lineJoinStyle = .round
    context.saveGState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.white.withAlphaComponent(0.55)
    glow.shadowBlurRadius = 36
    glow.set()
    NSColor.white.setStroke()
    pulse.stroke()
    context.restoreGState()
    context.restoreGState()

    // Hairline edge for definition on light backgrounds.
    NSColor.white.withAlphaComponent(0.22).setStroke()
    let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 185, yRadius: 185)
    edge.lineWidth = 3
    edge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: CGFloat(base * factor)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
try render(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("docs/icon.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
