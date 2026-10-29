// Prints WindowServer's window list as JSON (metadata only; needs no permissions).
// Usage: windows [owner-name] | windows --displays
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first
if owner == "--displays" {
    // Active displays in global top-left points, with their pixel size (for recordings).
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
    let displays: [[String: Any]] = ids.prefix(Int(count)).map { id in
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        return [
            "id": Int(id), "main": CGDisplayIsMain(id) != 0,
            "x": bounds.origin.x, "y": bounds.origin.y, "w": bounds.width, "h": bounds.height,
            "pixelWidth": mode?.pixelWidth ?? Int(bounds.width), "pixelHeight": mode?.pixelHeight ?? Int(bounds.height),
        ]
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: displays, options: [.sortedKeys]))
    exit(0)
}
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let windows: [[String: Any]] = list.compactMap { window in
    let name = window[kCGWindowOwnerName as String] as? String ?? ""
    if let owner, name != owner { return nil }
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return [
        "id": window[kCGWindowNumber as String] as? Int ?? 0,
        "pid": window[kCGWindowOwnerPID as String] as? Int ?? 0,
        "owner": name,
        "layer": window[kCGWindowLayer as String] as? Int ?? 0,
        "onscreen": window[kCGWindowIsOnscreen as String] as? Bool ?? false,
        "x": bounds["X"] ?? 0,
        "y": bounds["Y"] ?? 0,
        "w": bounds["Width"] ?? 0,
        "h": bounds["Height"] ?? 0,
    ]
}
let data = try JSONSerialization.data(withJSONObject: windows, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
