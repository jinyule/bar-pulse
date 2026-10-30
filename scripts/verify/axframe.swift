// Prints the frames (global top-left points) of every accessibility element of a process whose
// title or description equals the given text, as JSON. Needs Accessibility permission.
// Usage: axframe <pid> <title>
import ApplicationServices
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, let pid = pid_t(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: axframe <pid> <title>\n".utf8))
    exit(2)
}
let title = arguments[2]

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position: AXValue = attribute(element, kAXPositionAttribute),
          let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    AXValueGetValue(position, .cgPoint, &origin)
    AXValueGetValue(size, .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
}

var found: [[String: Any]] = []
func walk(_ element: AXUIElement, depth: Int) {
    guard depth < 12 else { return }
    let names = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0) as String? }
    if names.contains(title), let rect = frame(element) {
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        found.append(["role": role, "x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height])
    }
    for child in attribute(element, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
        walk(child, depth: depth + 1)
    }
}
walk(AXUIElementCreateApplication(pid), depth: 0)
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: found, options: [.sortedKeys]))
