import Foundation

public enum TemperatureUnit: String, Sendable, Codable, CaseIterable {
    case celsius
    case fahrenheit

    public func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }
}

public enum Format {
    /// `0.234` → `"23%"`.
    public static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    /// `0.234` → `"23.4%"`, used where a decimal matters (user/system split).
    public static func precisePercent(_ fraction: Double) -> String {
        String(format: "%.1f%%", min(1, max(0, fraction)) * 100)
    }

    /// Binary units, as Activity Monitor reports memory: `41_000_000_000` → `"38.2 GB"`.
    public static func bytes(_ value: UInt64) -> String {
        let (number, unit) = scaled(Double(value), units: ["B", "KB", "MB", "GB", "TB"])
        return "\(number) \(unit)"
    }

    /// Splits a throughput into number and unit so the UI can style them separately.
    /// Always starts at KB/s and keeps at most three significant digits: `"0.4" KB/s`, `"12.6" MB/s`, `"812" KB/s`.
    public static func rateParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let units = ["KB/s", "MB/s", "GB/s", "TB/s"]
        var value = max(0, bytesPerSecond) / 1024
        var index = 0
        while value >= 999.5 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return (value < 99.95 ? String(format: "%.1f", value) : String(format: "%.0f", value), units[index])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        let parts = rateParts(bytesPerSecond)
        return "\(parts.value) \(parts.unit)"
    }

    /// `56.4` → `"56°"`.
    public static func temperature(_ celsius: Double?, unit: TemperatureUnit = .celsius) -> String {
        guard let celsius else { return "--" }
        return "\(Int(unit.convert(celsius).rounded()))°"
    }

    /// Uptime-style durations: `"3 天 4 小时"`, `"5 小时 12 分"`, `"8 分钟"`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes % 60) 分" }
        return "\(minutes) 分钟"
    }

    static func scaled(_ value: Double, units: [String]) -> (String, String) {
        var value = max(0, value)
        var index = 0
        while value >= 1000 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return (String(format: "%.0f", value), units[0]) }
        return (value < 99.95 ? String(format: "%.1f", value) : String(format: "%.0f", value), units[index])
    }
}

/// Fixed-capacity sliding window of samples, oldest first.
public struct History: Sendable, Equatable {
    public let capacity: Int
    public private(set) var values: [Double] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ value: Double) {
        values.append(value.isFinite ? value : 0)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    public var last: Double? { values.last }
    public var peak: Double { values.max() ?? 0 }
}
