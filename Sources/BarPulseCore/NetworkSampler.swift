import Darwin
import Foundation
import SystemConfiguration

public struct NetworkSnapshot: Sendable, Codable {
    /// Bytes per second.
    public var downloadRate: Double = 0
    public var uploadRate: Double = 0
    /// Bytes transferred since the sampler started.
    public var sessionDownloaded: UInt64 = 0
    public var sessionUploaded: UInt64 = 0
    /// Bytes transferred since boot on the counted interfaces.
    public var totalDownloaded: UInt64 = 0
    public var totalUploaded: UInt64 = 0
    /// BSD name of the primary interface, e.g. `en0`.
    public var interface: String?
    /// Human readable name, e.g. `Wi-Fi`.
    public var interfaceDisplayName: String?
    public var localAddress: String?

    public init() {}
}

/// Measures throughput from the 64-bit per-interface counters exposed by the `IFMIB` sysctl.
///
/// Only physical interfaces (`en*`, cellular) are summed: VPN tunnels and VM bridges
/// re-route the same bytes through the physical link, so counting them would double up.
public final class NetworkSampler: @unchecked Sendable {
    struct Counters: Equatable {
        var received: UInt64
        var sent: UInt64
    }

    private var last: Counters?
    private var lastTime: UInt64 = 0
    private var baseline: Counters?
    private var sessionReceived: UInt64 = 0
    private var sessionSent: UInt64 = 0

    private let store = SCDynamicStoreCreate(nil, "BarPulse" as CFString, nil, nil)
    private var refreshCountdown = 0
    private var cachedInterface: String?
    private var cachedDisplayName: String?
    private var cachedAddress: String?

    public init() {
        refreshInterfaceInfo()
        last = Self.readCounters(primary: cachedInterface)
        lastTime = clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    public func sample() -> NetworkSnapshot {
        if refreshCountdown <= 0 {
            refreshInterfaceInfo()
            refreshCountdown = 5
        }
        refreshCountdown -= 1

        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        let counters = Self.readCounters(primary: cachedInterface)
        var snapshot = NetworkSnapshot()
        snapshot.interface = cachedInterface
        snapshot.interfaceDisplayName = cachedDisplayName
        snapshot.localAddress = cachedAddress
        snapshot.totalDownloaded = counters.received
        snapshot.totalUploaded = counters.sent

        if let last, now > lastTime {
            let seconds = Double(now - lastTime) / 1_000_000_000
            // Interfaces can disappear (counters drop); treat that interval as zero traffic.
            let received = counters.received >= last.received ? counters.received - last.received : 0
            let sent = counters.sent >= last.sent ? counters.sent - last.sent : 0
            sessionReceived += received
            sessionSent += sent
            if seconds > 0 {
                snapshot.downloadRate = Double(received) / seconds
                snapshot.uploadRate = Double(sent) / seconds
            }
        }
        snapshot.sessionDownloaded = sessionReceived
        snapshot.sessionUploaded = sessionSent
        last = counters
        lastTime = now
        return snapshot
    }

    static func isCounted(_ name: String, primary: String?) -> Bool {
        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") { return true }
        // A non-tunnel primary interface (e.g. a USB modem) should count too.
        if let primary, name == primary, !name.hasPrefix("utun"), !name.hasPrefix("ipsec") { return true }
        return false
    }

    static func readCounters(primary: String?) -> Counters {
        var counters = Counters(received: 0, sent: 0)
        guard let list = if_nameindex() else { return counters }
        defer { if_freenameindex(list) }
        var entry = list
        while entry.pointee.if_index != 0, let name = entry.pointee.if_name {
            defer { entry += 1 }
            guard isCounted(String(cString: name), primary: primary),
                  let data = interfaceData(index: entry.pointee.if_index) else { continue }
            counters.received &+= data.ifi_ibytes
            counters.sent &+= data.ifi_obytes
        }
        return counters
    }

    /// Exact 64-bit counters for one interface.
    ///
    /// `NET_RT_IFLIST2` is not used on purpose: recent macOS versions round its byte counters
    /// to 1 KiB and truncate them to 32 bits for unprivileged callers, which breaks totals
    /// and makes low rates step in 1 KiB increments.
    static func interfaceData(index: UInt32) -> if_data64? {
        var row = ifmibdata()
        var size = MemoryLayout<ifmibdata>.size
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
        guard sysctl(&mib, UInt32(mib.count), &row, &size, nil, 0) == 0 else { return nil }
        return row.ifmd_data
    }

    private func refreshInterfaceInfo() {
        var primary: String?
        if let store,
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            primary = global["PrimaryInterface"] as? String
        }
        if primary != cachedInterface || cachedDisplayName == nil {
            cachedDisplayName = primary.flatMap(Self.displayName(for:))
        }
        cachedInterface = primary
        cachedAddress = primary.flatMap(Self.ipv4Address(for:))
    }

    static func displayName(for bsdName: String) -> String? {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for interface in interfaces where SCNetworkInterfaceGetBSDName(interface) as String? == bsdName {
            return SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
        }
        if bsdName.hasPrefix("utun") { return "VPN" }
        return nil
    }

    static func ipv4Address(for bsdName: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == bsdName else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
