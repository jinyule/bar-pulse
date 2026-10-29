import Foundation
import IOKit

public struct GPUSnapshot: Sendable, Codable {
    /// Overall device utilisation, 0...1.
    public var usage: Double = 0
    public var renderer: Double = 0
    public var tiler: Double = 0
    /// Bytes of system memory currently in use by the GPU driver.
    public var memoryInUse: UInt64?
    public var available = false

    public init() {}
}

/// Reads the `PerformanceStatistics` dictionary that the GPU driver publishes on its IOAccelerator node.
/// No elevated privileges are required.
public final class GPUSampler: @unchecked Sendable {
    public private(set) var model: String?
    public private(set) var coreCount: Int?
    private var entry: io_registry_entry_t = 0

    public init() {
        locate()
    }

    deinit {
        if entry != 0 { IOObjectRelease(entry) }
    }

    public func sample() -> GPUSnapshot {
        if entry == 0 { locate() }
        guard entry != 0, let stats = Self.statistics(of: entry) else {
            // The accelerator can be re-registered (e.g. GPU switch); look it up again next time.
            if entry != 0 { IOObjectRelease(entry); entry = 0 }
            return GPUSnapshot()
        }
        var snapshot = GPUSnapshot()
        snapshot.available = true
        let device = Self.number(stats, "Device Utilization %") ?? Self.number(stats, "GPU Activity(%)") ?? 0
        snapshot.usage = min(1, max(0, device / 100))
        snapshot.renderer = min(1, max(0, (Self.number(stats, "Renderer Utilization %") ?? 0) / 100))
        snapshot.tiler = min(1, max(0, (Self.number(stats, "Tiler Utilization %") ?? 0) / 100))
        if let memory = Self.number(stats, "In use system memory") ?? Self.number(stats, "vramUsedBytes") {
            snapshot.memoryInUse = UInt64(max(0, memory))
        }
        return snapshot
    }

    private func locate() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            if Self.statistics(of: service) != nil {
                entry = service
                model = Self.property(service, "model") as? String
                if let data = Self.property(service, "model") as? Data {
                    model = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                }
                coreCount = (Self.property(service, "gpu-core-count") as? NSNumber)?.intValue
                return
            }
            IOObjectRelease(service)
        }
    }

    private static func statistics(of entry: io_registry_entry_t) -> [String: Any]? {
        property(entry, "PerformanceStatistics") as? [String: Any]
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func number(_ dictionary: [String: Any], _ key: String) -> Double? {
        (dictionary[key] as? NSNumber)?.doubleValue
    }
}
