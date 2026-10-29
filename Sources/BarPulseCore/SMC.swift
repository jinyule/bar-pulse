import Foundation
import IOKit

/// Minimal read-only client for the System Management Controller.
///
/// Mirrors the `SMCKeyData_t` layout used by the AppleSMC user client (selector 2).
final class SMC {
    private struct KeyData {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct LimitData { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }

        var key: UInt32 = 0
        var version = Version()
        var limitData = LimitData()
        var keyInfo = KeyInfo()
        // Swift packs fields after `keyInfo` at its size (9), C at its stride (12); pad to match.
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    struct KeyInfo {
        let size: Int
        let type: UInt32
    }

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    static func code(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Enumerates every key the SMC exposes (several thousand on Apple Silicon).
    func allKeys() -> [UInt32] {
        guard let raw = readRaw(Self.code("#KEY")), raw.bytes.count >= 4 else { return [] }
        let count = raw.bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var keys: [UInt32] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<count {
            var input = KeyData()
            input.command = Command.readIndex.rawValue
            input.data32 = index
            if let output = call(&input) { keys.append(output.key) }
        }
        return keys
    }

    func keyInfo(_ key: UInt32) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var input = KeyData()
        input.key = key
        input.command = Command.readKeyInfo.rawValue
        guard let output = call(&input) else { return nil }
        let info = KeyInfo(size: Int(output.keyInfo.dataSize), type: output.keyInfo.dataType)
        infoCache[key] = info
        return info
    }

    func readRaw(_ key: UInt32) -> (type: UInt32, bytes: [UInt8])? {
        guard let info = keyInfo(key), info.size > 0, info.size <= 32 else { return nil }
        var input = KeyData()
        input.key = key
        input.keyInfo.dataSize = UInt32(info.size)
        input.command = Command.readBytes.rawValue
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(info.size)) }
        return (info.type, bytes)
    }

    /// Reads a key and decodes the common numeric SMC encodings.
    func readNumber(_ key: UInt32) -> Double? {
        guard let (type, bytes) = readRaw(key) else { return nil }
        return Self.decode(type: Self.string(type), bytes: bytes)
    }

    func readNumber(_ key: String) -> Double? {
        readNumber(Self.code(key))
    }

    static func decode(type: String, bytes: [UInt8]) -> Double? {
        func bigEndian(_ count: Int) -> UInt64? {
            guard bytes.count >= count else { return nil }
            return bytes.prefix(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "sp78":
            return bigEndian(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        case "fpe2":
            return bigEndian(2).map { Double($0) / 4 }
        case "ui8 ":
            return bigEndian(1).map { Double($0) }
        case "ui16":
            return bigEndian(2).map { Double($0) }
        case "ui32":
            return bigEndian(4).map { Double($0) }
        default:
            return nil
        }
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &outputSize)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }
}
