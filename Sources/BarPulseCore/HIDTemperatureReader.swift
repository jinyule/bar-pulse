import Foundation
import IOKit

/// Reads temperature sensors through the (private) IOHIDEventSystem API.
///
/// This is the fallback/companion to the SMC: it exposes the SoC die sensors (`PMU tdie*`),
/// the SSD controller (`NAND CH0 temp`) and the battery gas gauge without any entitlements.
final class HIDTemperatureReader {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatValue = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    struct Reading {
        let name: String
        let value: Double
    }

    private let client: AnyObject
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let getFloatValue: GetFloatValue
    private var services: [(name: String, service: AnyObject)] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = load("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let getFloatValue = load("IOHIDEventGetFloatValue", as: GetFloatValue.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        // Usage page 0xff00 / usage 5 = AppleVendor temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        self.client = client
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloatValue = getFloatValue
        refreshServices()
    }

    private func refreshServices() {
        guard let list = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return }
        // Several PMUs publish the same sensor names with matching readings; one of each is enough.
        var seen = Set<String>()
        services = list.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  Self.isInteresting(name), seen.insert(name).inserted else { return nil }
            return (name, service)
        }
    }

    static func isInteresting(_ name: String) -> Bool {
        name.hasPrefix("PMU tdie") || name.hasPrefix("NAND") || name.hasPrefix("gas gauge")
    }

    func read() -> [Reading] {
        services.compactMap { entry in
            guard let event = copyEvent(entry.service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { return nil }
            let value = getFloatValue(event, Self.temperatureField)
            guard value.isFinite, value > 0, value < 150 else { return nil }
            return Reading(name: entry.name, value: value)
        }
    }
}
