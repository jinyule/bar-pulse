import Darwin
import Foundation

public enum MemoryPressure: Int, Sendable, Codable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var displayName: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "紧张"
        }
    }
}

/// Memory breakdown using the same buckets as Activity Monitor.
public struct MemorySnapshot: Sendable, Codable {
    public var total: UInt64 = 0
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var cached: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var pressure: MemoryPressure = .normal

    public var used: UInt64 { app + wired + compressed }
    public var free: UInt64 { total > used ? total - used : 0 }
    public var usage: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }

    public init() {}
}

public final class MemorySampler: @unchecked Sendable {
    private let host = mach_host_self()
    private let pageSize: UInt64
    public let totalMemory: UInt64

    public init() {
        pageSize = UInt64(Sysctl.int("hw.pagesize") ?? Int(getpagesize()))
        totalMemory = UInt64(Sysctl.int("hw.memsize") ?? Int(ProcessInfo.processInfo.physicalMemory))
    }

    public func sample() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        snapshot.total = totalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            let external = UInt64(stats.external_page_count)
            snapshot.app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
            snapshot.wired = UInt64(stats.wire_count) * pageSize
            snapshot.compressed = UInt64(stats.compressor_page_count) * pageSize
            snapshot.cached = (external + purgeable) * pageSize
        }

        if let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self) {
            snapshot.swapUsed = swap.xsu_used
            snapshot.swapTotal = swap.xsu_total
        }
        if let level = Sysctl.int("kern.memorystatus_vm_pressure_level"), let pressure = MemoryPressure(rawValue: level) {
            snapshot.pressure = pressure
        }
        return snapshot
    }
}
