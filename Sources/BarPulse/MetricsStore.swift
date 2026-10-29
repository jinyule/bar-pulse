import BarPulseCore
import Foundation
import Observation

/// Samples the system on a background queue and publishes snapshots + rolling history on the main actor.
@Observable
@MainActor
final class MetricsStore {
    static let historyLength = 90

    private(set) var snapshot = SystemSnapshot()
    private(set) var cpu = History(capacity: historyLength)
    private(set) var cpuSystem = History(capacity: historyLength)
    private(set) var gpu = History(capacity: historyLength)
    private(set) var memory = History(capacity: historyLength)
    private(set) var download = History(capacity: historyLength)
    private(set) var upload = History(capacity: historyLength)
    private(set) var cpuTemperature = History(capacity: historyLength)
    private(set) var gpuTemperature = History(capacity: historyLength)
    private(set) var sampleCount = 0
    let info: SystemInfo

    @ObservationIgnored var onSample: (() -> Void)?
    @ObservationIgnored private let monitor: SystemMonitor
    @ObservationIgnored private let queue = DispatchQueue(label: "dev.barpulse.sampler", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?

    init() {
        monitor = SystemMonitor()
        info = monitor.info
    }

    func start(interval: TimeInterval) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Fire quickly once so the menu bar fills in right after launch.
        timer.schedule(deadline: .now() + .milliseconds(400), repeating: interval, leeway: .milliseconds(50))
        let monitor = self.monitor
        timer.setEventHandler { [weak self] in
            let snapshot = monitor.sample()
            Task { @MainActor in self?.apply(snapshot) }
        }
        timer.resume()
        self.timer = timer
    }

    private func apply(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        cpu.append(snapshot.cpu.usage)
        cpuSystem.append(snapshot.cpu.system)
        gpu.append(snapshot.gpu.usage)
        memory.append(snapshot.memory.usage)
        download.append(snapshot.network.downloadRate)
        upload.append(snapshot.network.uploadRate)
        if let value = snapshot.thermal.cpu ?? snapshot.thermal.soc { cpuTemperature.append(value) }
        if let value = snapshot.thermal.gpu { gpuTemperature.append(value) }
        sampleCount += 1
        onSample?()
    }
}
