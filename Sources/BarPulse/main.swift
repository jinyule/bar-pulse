import AppKit
import BarPulseCore

let arguments = CommandLine.arguments

if arguments.contains("--dump") {
    // Headless mode used by verification scripts.
    //   --dump                 one pretty-printed JSON document (system info + snapshot)
    //   --dump --watch         one compact JSON snapshot per line, forever
    //   --interval <seconds>   sampling interval (default 1)
    let interval = arguments.firstIndex(of: "--interval")
        .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 1
    let monitor = SystemMonitor()
    _ = monitor.sample()

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if arguments.contains("--watch") {
        encoder.outputFormatting = [.sortedKeys]
        setvbuf(stdout, nil, _IOLBF, 0)
        while true {
            Thread.sleep(forTimeInterval: interval)
            let line = try encoder.encode(monitor.sample())
            FileHandle.standardOutput.write(line + Data("\n".utf8))
        }
    }

    struct Dump: Encodable {
        let info: SystemInfo
        let snapshot: SystemSnapshot
    }
    Thread.sleep(forTimeInterval: interval)
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Dump(info: monitor.info, snapshot: monitor.sample()))
    FileHandle.standardOutput.write(data + Data("\n".utf8))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
