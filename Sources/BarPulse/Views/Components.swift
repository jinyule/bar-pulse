import AppKit
import BarPulseCore
import SwiftUI

// MARK: - Containers

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // A fairly solid surface keeps text legible on top of the popover's glass.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                }
        }
    }
}

struct IconTile: View {
    let symbol: String
    let tint: NSColor
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(nsColor: tint.blended(withFraction: 0.22, of: .white) ?? tint), Color(nsColor: tint)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: Color(nsColor: tint).opacity(0.35), radius: 3, y: 1)
    }
}

struct CardHeader: View {
    let symbol: String
    let tint: NSColor
    let title: String
    let subtitle: String
    var value: String?
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let value {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
            }
        }
    }
}

// MARK: - Charts

struct ChartSeries {
    var values: [Double]
    var color: Color
    var filled = true
    var lineWidth: CGFloat = 1.6
}

enum ChartGeometry {
    /// Right-aligns the samples so the newest value always sits on the right edge.
    static func points(_ values: [Double], capacity: Int, range: ClosedRange<Double>, in rect: CGRect, downward: Bool = false) -> [CGPoint] {
        guard values.count > 1, capacity > 1 else { return [] }
        let step = rect.width / CGFloat(capacity - 1)
        let offset = capacity - values.count
        let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
        return values.enumerated().map { index, value in
            let fraction = CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
            let y = downward ? rect.minY + fraction * rect.height : rect.maxY - fraction * rect.height
            return CGPoint(x: CGFloat(offset + index) * step, y: y)
        }
    }

    /// Midpoint-quadratic smoothing: curvy, but never overshoots the data range.
    static func smoothLine(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2), control: previous)
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }

    static func draw(_ series: ChartSeries, in context: GraphicsContext, rect: CGRect, capacity: Int,
                     range: ClosedRange<Double>, downward: Bool = false, showsDot: Bool = true) {
        let points = points(series.values, capacity: capacity, range: range, in: rect, downward: downward)
        guard let first = points.first, let last = points.last else { return }
        let line = smoothLine(points)
        if series.filled {
            let baseline = downward ? rect.minY : rect.maxY
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: baseline))
            area.addLine(to: CGPoint(x: first.x, y: baseline))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [series.color.opacity(0.34), series.color.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: downward ? rect.maxY : rect.minY),
                endPoint: CGPoint(x: 0, y: baseline)
            ))
        }
        context.stroke(line, with: .color(series.color),
                       style: StrokeStyle(lineWidth: series.lineWidth, lineCap: .round, lineJoin: .round))
        if showsDot {
            context.fill(Path(ellipseIn: CGRect(x: last.x - 4.5, y: last.y - 4.5, width: 9, height: 9)), with: .color(series.color.opacity(0.22)))
            context.fill(Path(ellipseIn: CGRect(x: last.x - 2.4, y: last.y - 2.4, width: 4.8, height: 4.8)), with: .color(series.color))
        }
    }
}

struct AreaChart: View {
    var series: [ChartSeries]
    var range: ClosedRange<Double> = 0...1
    var capacity = MetricsStore.historyLength
    var gridLines = 3

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 0, y: 5, width: size.width - 5, height: size.height - 6)
            for line in 0...gridLines {
                let y = rect.minY + rect.height * CGFloat(line) / CGFloat(gridLines)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                let solid = line == gridLines
                context.stroke(path, with: .color(.primary.opacity(solid ? 0.12 : 0.06)),
                               style: StrokeStyle(lineWidth: 0.5, dash: solid ? [] : [2, 3]))
            }
            for item in series {
                ChartGeometry.draw(item, in: context, rect: rect, capacity: capacity, range: range)
            }
        }
    }
}

/// Download above the axis, upload mirrored below it, on a shared auto-scaled range.
struct MirrorChart: View {
    var download: [Double]
    var upload: [Double]
    var capacity = MetricsStore.historyLength

    var scale: Double {
        max(64 * 1024, max(download.max() ?? 0, upload.max() ?? 0) * 1.15)
    }

    var body: some View {
        Canvas { context, size in
            let mid = (size.height / 2).rounded()
            let upper = CGRect(x: 0, y: 5, width: size.width - 5, height: mid - 5)
            let lower = CGRect(x: 0, y: mid, width: size.width - 5, height: mid - 5)
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(axis, with: .color(.primary.opacity(0.14)), lineWidth: 0.5)
            ChartGeometry.draw(ChartSeries(values: download, color: .download), in: context, rect: upper,
                               capacity: capacity, range: 0...scale)
            ChartGeometry.draw(ChartSeries(values: upload, color: .upload), in: context, rect: lower,
                               capacity: capacity, range: 0...scale, downward: true)
        }
        .overlay(alignment: .topLeading) {
            Text("峰值 \(Format.rate(max(download.max() ?? 0, upload.max() ?? 0)))")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
    }
}

// MARK: - Bars

struct CoreGrid: View {
    let cores: [Double]
    let clusters: [CPUCluster]
    private let barHeight: CGFloat = 30
    private let clusterGap: CGFloat = 12
    private let barGap: CGFloat = 2.5

    var body: some View {
        GeometryReader { geometry in
            let total = max(1, clusters.reduce(0) { $0 + $1.count })
            let gaps = clusterGap * CGFloat(max(0, clusters.count - 1)) + barGap * CGFloat(max(0, total - clusters.count))
            let barWidth = max(2, (geometry.size.width - gaps) / CGFloat(total))
            HStack(alignment: .top, spacing: clusterGap) {
                ForEach(Array(clusters.enumerated()), id: \.offset) { index, cluster in
                    let color = index == clusters.count - 1 ? Color.cpu : Color.cpuAlt
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .bottom, spacing: barGap) {
                            ForEach(cluster.range, id: \.self) { core in
                                CoreBar(value: core < cores.count ? cores[core] : 0, color: color, width: barWidth, height: barHeight)
                            }
                        }
                        HStack(spacing: 4) {
                            Circle().fill(color).frame(width: 5, height: 5)
                            Text("\(cluster.displayName) × \(cluster.count)")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(height: barHeight + 18)
    }
}

private struct CoreBar: View {
    let value: Double
    let color: Color
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let radius = min(2.5, width / 2)
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [color, color.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .frame(height: max(2, height * CGFloat(min(1, max(0, value)))))
        }
        .frame(width: width, height: height)
        .animation(.smooth(duration: 0.45), value: value)
    }
}

struct SegmentBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    let total: Double

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: max(0, geometry.size.width * segment.value / max(total, 1) - 1.5))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.07))
            .clipShape(Capsule())
            .animation(.smooth(duration: 0.5), value: segments.map(\.value))
        }
        .frame(height: 10)
    }
}

struct MeterRow: View {
    let title: String
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(fraction)).monospacedDigit()
            }
            .font(.system(size: 10.5, weight: .medium))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.6), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geometry.size.width * CGFloat(min(1, max(0, fraction)))))
                }
            }
            .frame(height: 5)
            .animation(.smooth(duration: 0.45), value: fraction)
        }
    }
}

// MARK: - Small pieces

struct StatItem: View {
    let title: String
    let value: String
    var dot: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                Text(title)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LegendItem: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color.gradient)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct SensorTile: View {
    let title: String
    let celsius: Double?
    let unit: TemperatureUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(Format.temperature(celsius, unit: unit))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(celsius == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let celsius {
                        Capsule()
                            .fill(LinearGradient(colors: [Color.heat(30), Color.heat(celsius)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geometry.size.width * Theme.heatFraction(celsius)))
                    }
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct FanTile: View {
    let fan: FanReading

    var body: some View {
        HStack(spacing: 9) {
            SpinningSymbol(systemName: "fanblades.fill", pointSize: 16,
                           color: fan.rpm > 0 ? Theme.download : .secondaryLabelColor, spinning: fan.rpm > 0)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("风扇 \(fan.id + 1)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(fan.rpm > 0 ? "\(Int(fan.rpm.rounded())) RPM" : "静止")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            if fan.maximum > 0 {
                Text(Format.percent(fan.rpm / fan.maximum))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .help(fan.maximum > 0 ? "转速范围 \(Int(fan.minimum))–\(Int(fan.maximum)) RPM" : "")
    }
}

struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
