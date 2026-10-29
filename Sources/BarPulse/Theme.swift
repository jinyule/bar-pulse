import AppKit
import SwiftUI

enum Metric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, network, temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .network: return "网速"
        case .temperature: return "温度"
        }
    }

    /// Caption drawn above the value in the stacked menu bar layout.
    var caption: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "MEM"
        case .network: return "NET"
        case .temperature: return "TEMP"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "cube.transparent"
        case .memory: return "memorychip"
        case .network: return "network"
        case .temperature: return "thermometer.medium"
        }
    }

    /// Solid variants read better at menu bar size than the outlined dashboard glyphs.
    var menuBarSymbol: String {
        switch self {
        case .gpu: return "cube.fill"
        case .memory: return "memorychip.fill"
        default: return symbol
        }
    }
}

/// One palette shared by the menu bar renderer (AppKit) and the dashboard (SwiftUI).
enum Theme {
    static let cpu = NSColor(srgbRed: 0.24, green: 0.60, blue: 1.00, alpha: 1)
    static let cpuAlt = NSColor(srgbRed: 0.25, green: 0.82, blue: 0.93, alpha: 1)
    static let gpu = NSColor(srgbRed: 0.69, green: 0.42, blue: 1.00, alpha: 1)
    static let memory = NSColor(srgbRed: 0.20, green: 0.80, blue: 0.52, alpha: 1)
    static let wired = NSColor(srgbRed: 0.98, green: 0.72, blue: 0.24, alpha: 1)
    static let compressed = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.60, alpha: 1)
    static let download = NSColor(srgbRed: 0.18, green: 0.72, blue: 0.98, alpha: 1)
    static let upload = NSColor(srgbRed: 1.00, green: 0.56, blue: 0.24, alpha: 1)
    static let thermal = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.30, alpha: 1)

    static func color(for metric: Metric) -> NSColor {
        switch metric {
        case .cpu: return cpu
        case .gpu: return gpu
        case .memory: return memory
        case .network: return download
        case .temperature: return thermal
        }
    }

    private static let heatStops: [(Double, NSColor)] = [
        (35, NSColor(srgbRed: 0.20, green: 0.80, blue: 0.52, alpha: 1)),
        (60, NSColor(srgbRed: 0.96, green: 0.80, blue: 0.26, alpha: 1)),
        (80, NSColor(srgbRed: 1.00, green: 0.56, blue: 0.24, alpha: 1)),
        (95, NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)),
    ]

    /// Green → yellow → orange → red across the normal operating range of Apple silicon.
    static func heat(_ celsius: Double) -> NSColor {
        guard let first = heatStops.first, let last = heatStops.last else { return thermal }
        if celsius <= first.0 { return first.1 }
        if celsius >= last.0 { return last.1 }
        for (lower, upper) in zip(heatStops, heatStops.dropFirst()) where celsius <= upper.0 {
            let t = CGFloat((celsius - lower.0) / (upper.0 - lower.0))
            return lower.1.blended(withFraction: t, of: upper.1) ?? upper.1
        }
        return last.1
    }

    /// Maps a temperature onto 0...1 for gauges (20 °C → empty, 105 °C → full).
    static func heatFraction(_ celsius: Double) -> Double {
        min(1, max(0, (celsius - 20) / 85))
    }
}

extension Color {
    static let cpu = Color(nsColor: Theme.cpu)
    static let cpuAlt = Color(nsColor: Theme.cpuAlt)
    static let gpu = Color(nsColor: Theme.gpu)
    static let memory = Color(nsColor: Theme.memory)
    static let wired = Color(nsColor: Theme.wired)
    static let compressed = Color(nsColor: Theme.compressed)
    static let download = Color(nsColor: Theme.download)
    static let upload = Color(nsColor: Theme.upload)
    static let thermal = Color(nsColor: Theme.thermal)

    static func heat(_ celsius: Double) -> Color { Color(nsColor: Theme.heat(celsius)) }
}
