import Darwin
import Foundation

/// A group of logical CPUs that share a performance level (e.g. Super / Performance / Efficiency).
public struct CPUCluster: Sendable, Hashable, Codable {
    public let name: String
    public let displayName: String
    public let range: Range<Int>

    public var count: Int { range.count }
}

public struct CPUSnapshot: Sendable, Codable {
    /// Busy fraction across all cores, 0...1.
    public var usage: Double = 0
    public var user: Double = 0
    public var system: Double = 0
    /// Busy fraction per logical CPU, 0...1, in logical CPU order.
    public var cores: [Double] = []
    public var loadAverage: [Double] = [0, 0, 0]

    public init() {}
}

/// Samples per-core tick counters via `host_processor_info` and turns deltas into usage fractions.
public final class CPUSampler: @unchecked Sendable {
    struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    public let coreCount: Int
    public let clusters: [CPUCluster]

    private let host = mach_host_self()
    private var previous: [Ticks]

    public init() {
        let count = Sysctl.int("hw.ncpu") ?? ProcessInfo.processInfo.activeProcessorCount
        coreCount = count
        clusters = Self.detectClusters(total: count)
        previous = []
        previous = readTicks() ?? []
    }

    public func sample() -> CPUSnapshot {
        guard let now = readTicks() else { return CPUSnapshot() }
        defer { previous = now }
        var snapshot = CPUSnapshot()
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { snapshot.loadAverage = loads }
        guard previous.count == now.count else { return snapshot }

        var userTotal = 0.0, systemTotal = 0.0, allTotal = 0.0
        snapshot.cores.reserveCapacity(now.count)
        for (old, new) in zip(previous, now) {
            // Tick counters are 32-bit and may wrap; wrapping subtraction keeps the delta right.
            let user = Double(new.user &- old.user) + Double(new.nice &- old.nice)
            let system = Double(new.system &- old.system)
            let idle = Double(new.idle &- old.idle)
            let total = user + system + idle
            snapshot.cores.append(total > 0 ? min(1, (user + system) / total) : 0)
            userTotal += user
            systemTotal += system
            allTotal += total
        }
        if allTotal > 0 {
            snapshot.user = userTotal / allTotal
            snapshot.system = systemTotal / allTotal
            snapshot.usage = min(1, (userTotal + systemTotal) / allTotal)
        }
        return snapshot
    }

    private func readTicks() -> [Ticks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * stride
            return Ticks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// Logical CPUs are numbered starting from the lowest performance level
    /// (`hw.perflevel{n-1}`) up to `hw.perflevel0`, so we walk the levels in reverse.
    static func detectClusters(total: Int) -> [CPUCluster] {
        let fallback = [CPUCluster(name: "CPU", displayName: "核心", range: 0..<total)]
        let levels = Sysctl.int("hw.nperflevels") ?? 1
        guard levels > 1 else { return fallback }
        var clusters: [CPUCluster] = []
        var start = 0
        for level in stride(from: levels - 1, through: 0, by: -1) {
            guard let count = Sysctl.int("hw.perflevel\(level).logicalcpu"), count > 0 else { continue }
            let name = Sysctl.string("hw.perflevel\(level).name") ?? "Level \(level)"
            clusters.append(CPUCluster(name: name, displayName: localizedClusterName(name), range: start..<(start + count)))
            start += count
        }
        return start == total ? clusters : fallback
    }

    static func localizedClusterName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "super": return "超级核"
        case "performance": return "性能核"
        case "efficiency": return "能效核"
        default: return raw
        }
    }
}
