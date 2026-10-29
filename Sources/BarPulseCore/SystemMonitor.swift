import Foundation

/// Static facts about this Mac, gathered once at launch.
public struct SystemInfo: Sendable, Codable {
    public var chip: String
    public var cpuCores: Int
    public var clusters: [CPUCluster]
    public var gpuCores: Int?
    public var memory: UInt64
    public var osVersion: String
    public var bootDate: Date

    public var uptime: TimeInterval { Date().timeIntervalSince(bootDate) }
}

public struct SystemSnapshot: Sendable, Codable {
    public var date = Date()
    public var cpu = CPUSnapshot()
    public var memory = MemorySnapshot()
    public var network = NetworkSnapshot()
    public var gpu = GPUSnapshot()
    public var thermal = ThermalSnapshot()

    public init() {}
}

/// Owns every sampler. Not thread-safe: call `sample()` from one serial queue.
public final class SystemMonitor: @unchecked Sendable {
    public let info: SystemInfo

    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let network = NetworkSampler()
    private let gpu = GPUSampler()
    private let thermal = ThermalSampler()

    public init() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let bootTime = Sysctl.value("kern.boottime", as: timeval.self) ?? timeval()
        info = SystemInfo(
            chip: Sysctl.string("machdep.cpu.brand_string") ?? gpu.model ?? "Mac",
            cpuCores: cpu.coreCount,
            clusters: cpu.clusters,
            gpuCores: gpu.coreCount,
            memory: memory.totalMemory,
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
            bootDate: Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000)
        )
    }

    public func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpu = cpu.sample()
        snapshot.memory = memory.sample()
        snapshot.network = network.sample()
        snapshot.gpu = gpu.sample()
        snapshot.thermal = thermal.sample()
        return snapshot
    }
}
