import AppKit
import BarPulseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let store = MetricsStore()
    private var statusController: StatusItemController?
    private lazy var settingsWindow = SettingsWindowController(settings: settings, store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(store: store, settings: settings) { [weak self] screen in
            self?.settingsWindow.show(on: screen)
        }
        statusController = controller
        store.onSample = { [weak controller] in controller?.refresh() }

        var interval = settings.refreshInterval
        settings.onChange = { [weak self, weak controller] in
            guard let self else { return }
            controller?.refresh()
            self.settingsWindow.applyAppearance()
            if self.settings.refreshInterval != interval {
                interval = self.settings.refreshInterval
                self.store.start(interval: interval)
            }
        }
        store.start(interval: interval)

        // Debug aid for staging the settings window without clicking.
        if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.settingsWindow.show() }
        }
    }
}
