// Prints the mouse cursor position in global top-left points, or first moves it there with a
// real mouse-moved event (so the system notices which display is active), optionally clicking.
// Usage: cursor [x y [click]]   — moving needs Accessibility permission for the calling terminal.
import CoreGraphics
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let target = arguments.prefix(2).compactMap(Double.init)
if target.count == 2 {
    let point = CGPoint(x: target[0], y: target[1])
    var events: [CGEventType] = [.mouseMoved]
    if arguments.dropFirst(2).first == "click" { events += [.leftMouseDown, .leftMouseUp] }
    for type in events {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(60_000)
    }
    usleep(200_000)
}
let location = CGEvent(source: nil)?.location ?? .zero
print(location.x, location.y)
