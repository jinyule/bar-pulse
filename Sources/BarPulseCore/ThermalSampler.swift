import Foundation

public enum ThermalLevel: Int, Sendable, Codable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    public var displayName: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "温热"
        case .serious: return "过热"
        case .critical: return "危急"
        }
    }
}

public struct FanReading: Sendable, Codable, Identifiable {
    public var id: Int
    public var rpm: Double
    public var minimum: Double
    public var maximum: Double

    /// Position of the current speed inside the fan's operating range, 0...1.
    public var fraction: Double {
        guard maximum > minimum, rpm > 0 else { return 0 }
        return min(1, max(0, (rpm - minimum) / (maximum - minimum)))
    }
}

/// Temperatures in °C. Any sensor that isn't present on this Mac is `nil`.
public struct ThermalSnapshot: Sendable, Codable {
    public var cpu: Double?
    public var cpuPeak: Double?
    public var gpu: Double?
    public var memory: Double?
    public var soc: Double?
    public var ssd: Double?
    public var battery: Double?
    public var fans: [FanReading] = []
    public var level: ThermalLevel = .nominal

    /// The single number shown in the menu bar.
    public var headline: Double? { cpu ?? soc ?? gpu }

    public init() {}
}

public final class ThermalSampler: @unchecked Sendable {
    struct SensorGroups {
        var cpu: [UInt32] = []
        var gpu: [UInt32] = []
        var memory: [UInt32] = []
        var battery: [UInt32] = []
        var fanCount = 0
    }

    private let smc = SMC()
    private let hid = HIDTemperatureReader()
    private var groups: SensorGroups?

    public init() {}

    public func sample() -> ThermalSnapshot {
        if groups == nil { groups = discover() }
        var snapshot = ThermalSnapshot()
        snapshot.level = ThermalLevel(ProcessInfo.processInfo.thermalState)

        if let smc, let groups {
            let cpu = read(groups.cpu, from: smc)
            snapshot.cpu = Self.mean(cpu)
            snapshot.cpuPeak = cpu.max()
            snapshot.gpu = Self.mean(read(groups.gpu, from: smc))
            snapshot.memory = Self.mean(read(groups.memory, from: smc))
            snapshot.battery = Self.mean(read(groups.battery, from: smc))
            snapshot.fans = (0..<groups.fanCount).compactMap { index in
                guard let rpm = smc.readNumber("F\(index)Ac") else { return nil }
                return FanReading(
                    id: index,
                    rpm: max(0, rpm),
                    minimum: smc.readNumber("F\(index)Mn") ?? 0,
                    maximum: smc.readNumber("F\(index)Mx") ?? 0
                )
            }
        }

        if let readings = hid?.read() {
            snapshot.soc = Self.mean(readings.filter { $0.name.hasPrefix("PMU tdie") }.map(\.value))
            snapshot.ssd = readings.filter { $0.name.hasPrefix("NAND") }.map(\.value).max()
            if snapshot.battery == nil {
                snapshot.battery = Self.mean(readings.filter { $0.name.hasPrefix("gas gauge") }.map(\.value))
            }
        }
        return snapshot
    }

    private func read(_ keys: [UInt32], from smc: SMC) -> [Double] {
        keys.compactMap { key in
            guard let value = smc.readNumber(key), Self.isPlausible(value) else { return nil }
            return value
        }
    }

    /// Walks the SMC key list once and buckets temperature keys by their well-known prefixes.
    private func discover() -> SensorGroups {
        var groups = SensorGroups()
        guard let smc else { return groups }
        groups.fanCount = Int(smc.readNumber("FNum") ?? 0)

        var intelCPU: [UInt32] = [], intelGPU: [UInt32] = []
        for key in smc.allKeys() {
            let name = SMC.string(key)
            guard name.hasPrefix("T"), let value = smc.readNumber(key), Self.isPlausible(value) else { continue }
            switch name.prefix(2) {
            case "Tp", "Te": groups.cpu.append(key)       // Apple silicon CPU cores
            case "Tg": groups.gpu.append(key)             // Apple silicon GPU
            case "Tm": groups.memory.append(key)          // Apple silicon unified memory
            case "TC": intelCPU.append(key)               // Intel CPU die / proximity
            case "TG": intelGPU.append(key)               // Intel discrete / integrated GPU
            default:
                if ["TB0T", "TB1T", "TB2T"].contains(name) { groups.battery.append(key) }
            }
        }
        if groups.cpu.isEmpty { groups.cpu = intelCPU }
        if groups.gpu.isEmpty { groups.gpu = intelGPU }
        // Each SMC read is a round trip to the coprocessor (~0.3 ms). GPU and memory sensors in a
        // group read within a degree of each other, so an even spread of a few is plenty; CPU keys
        // are all kept so the hottest-core reading stays exact.
        groups.gpu = Self.spread(groups.gpu, limit: 6)
        groups.memory = Self.spread(groups.memory, limit: 4)
        return groups
    }

    static func spread<T>(_ items: [T], limit: Int) -> [T] {
        guard items.count > limit, limit > 0 else { return items }
        let step = Double(items.count) / Double(limit)
        return (0..<limit).map { items[Int(Double($0) * step)] }
    }

    static func isPlausible(_ value: Double) -> Bool {
        value > 5 && value < 130
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
