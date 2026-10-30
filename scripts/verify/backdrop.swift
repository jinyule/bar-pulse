// Shows an image in a borderless, click-through window covering a screen rect (global top-left
// points) until terminated, without activating. The UI checks put it behind the dashboard so the
// screenshots show a known picture through the glass rather than whatever windows are open. It
// floats above normal windows (so an app coming to the front can't cover it) but below the
// menu bar and the dashboard.
// Usage: backdrop x y w h image
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 5, let image = NSImage(contentsOfFile: arguments[4]) else {
    FileHandle.standardError.write(Data("usage: backdrop x y w h image\n".utf8))
    exit(2)
}
let values = arguments.prefix(4).compactMap(Double.init)
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
// Flip from the top-left global space (CoreGraphics) to AppKit's bottom-left space.
let rect = NSRect(x: values[0], y: primaryHeight - values[1] - values[3], width: values[2], height: values[3])

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = .floating
    window.ignoresMouseEvents = true
    window.hasShadow = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    let view = NSImageView(frame: NSRect(origin: .zero, size: rect.size))
    // Crop to fill rather than stretch: draw the image's centre at the window's aspect ratio.
    let side = min(image.size.width, image.size.height * rect.width / rect.height)
    let crop = NSRect(x: (image.size.width - side) / 2, y: (image.size.height - side * rect.height / rect.width) / 2,
                      width: side, height: side * rect.height / rect.width)
    view.image = NSImage(size: rect.size, flipped: false) { bounds in
        image.draw(in: bounds, from: crop, operation: .copy, fraction: 1)
        return true
    }
    window.contentView = view
    window.orderFrontRegardless()
    signal(SIGTERM) { _ in exit(0) }
    app.run()
}
