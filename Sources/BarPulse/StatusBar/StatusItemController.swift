import AppKit
import BarPulseCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let barView = StatusBarView()
    private var panel: DashboardPanel?
    private var dismissMonitors: [Any] = []
    private let store: MetricsStore
    private let settings: AppSettings
    /// Opens the settings window on the given screen (the one showing the status item).
    private let openSettings: (NSScreen?) -> Void

    init(store: MetricsStore, settings: AppSettings, openSettings: @escaping (NSScreen?) -> Void) {
        self.store = store
        self.settings = settings
        self.openSettings = openSettings
        super.init()

        statusItem.autosaveName = "BarPulseStatusItem"
        statusItem.behavior = []
        if let button = statusItem.button {
            barView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(barView)
            NSLayoutConstraint.activate([
                barView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                barView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                barView.topAnchor.constraint(equalTo: button.topAnchor),
                barView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityTitle("BarPulse")
            button.setAccessibilityHelp("显示 CPU、GPU、内存、网速与温度仪表盘")
        }

        refresh()
    }

    /// The dashboard is built on open and released on close, so a closed panel costs nothing:
    /// no SwiftUI graph updates, no animations, no backing stores. History lives in the store.
    private func makeDashboard() -> NSHostingController<DashboardView> {
        let dashboard = DashboardView(
            store: store,
            settings: settings,
            actions: DashboardActions(
                openActivityMonitor: { [weak self] in self?.openActivityMonitor() },
                openSettings: { [weak self] in
                    self?.closeDashboard()
                    self?.showSettings()
                },
                quit: { NSApp.terminate(nil) }
            )
        )
        return NSHostingController(rootView: dashboard)
    }

    /// Pushes the latest snapshot + settings into the menu bar view.
    func refresh() {
        let snapshot = store.snapshot
        if let panel {
            applySettings(to: panel)
        }
        barView.model = StatusBarModel(
            metrics: settings.visibleMetrics,
            layout: settings.layout,
            colorful: settings.colorful,
            unit: settings.temperatureUnit,
            cpu: snapshot.cpu.usage,
            gpu: snapshot.gpu.usage,
            memory: snapshot.memory.usage,
            pressure: snapshot.memory.pressure,
            download: snapshot.network.downloadRate,
            upload: snapshot.network.uploadRate,
            temperature: snapshot.thermal.headline
        )
        let width = barView.intrinsicContentSize.width
        if abs(statusItem.length - width) > 0.5 {
            statusItem.length = width
        }
        statusItem.button?.toolTip = tooltip(for: snapshot)
    }

    func showDashboard() {
        guard panel == nil, let button = statusItem.button else { return }
        let host = makeDashboard()
        // Measure once: the natural size is the default, the minimum bounds resizing.
        let ideal = host.view.intrinsicContentSize
        let minimum = host.sizeThatFits(in: .zero)
        host.sizingOptions = []

        let panel = DashboardPanel(content: host)
        panel.minimumSize = CGSize(width: minimum.width.rounded(.up), height: minimum.height.rounded(.up))
        panel.idealSize = CGSize(width: ideal.width.rounded(.up), height: ideal.height.rounded(.up))
        panel.onResize = { [weak self] size in self?.settings.dashboardSize = size }
        panel.onCancel = { [weak self] in self?.closeDashboard() }
        self.panel = panel
        applySettings(to: panel)
        panel.present()
        button.highlight(true)
        installDismissMonitors()
    }

    func closeDashboard() {
        guard let panel else { return }
        self.panel = nil
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        statusItem.button?.highlight(false)
        panel.dismiss()
    }

    private func applySettings(to panel: DashboardPanel) {
        let appearance = settings.appearance.nsAppearance
        if panel.appearance?.name != appearance?.name {
            panel.appearance = appearance
        }
        panel.backgroundOpacity = 1 - settings.dashboardTransparency
        let size = settings.dashboardSize ?? panel.idealSize
        if size != panel.requestedSize, let screen = statusItem.button?.window?.screen ?? NSScreen.main {
            panel.place(below: statusItemFrame ?? .zero, on: screen, size: size)
        }
    }

    /// The status item in screen coordinates.
    private var statusItemFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Closes the panel on a click anywhere else, or when the app loses focus, like a menu.
    private func installDismissMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The menu bar may be drawn by another process; a click on our own item then
                // shows up here first, and the item's action toggles the panel by itself.
                if self.statusItemFrame?.contains(NSEvent.mouseLocation) == true { return }
                self.closeDashboard()
            }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if event.window !== panel && event.window !== self.statusItem.button?.window {
                    self.closeDashboard()
                }
            }
            return event
        }
        dismissMonitors = [global, local].compactMap { $0 }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidResignActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        closeDashboard()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if panel != nil {
            closeDashboard()
        } else {
            showDashboard()
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        closeDashboard()
        let menu = NSMenu()
        menu.addItem(item("打开仪表盘", symbol: "gauge.with.dots.needle.67percent") { [weak self] in self?.showDashboard() })
        menu.addItem(item("活动监视器", symbol: "chart.bar.xaxis") { [weak self] in self?.openActivityMonitor() })
        menu.addItem(.separator())
        menu.addItem(item("设置…", symbol: "gearshape", key: ",") { [weak self] in self?.showSettings() })
        menu.addItem(.separator())
        menu.addItem(item("退出 BarPulse", symbol: "power", key: "q") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }

    private func item(_ title: String, symbol: String, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, handler: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func showSettings() {
        openSettings(statusItem.button?.window?.screen)
    }

    private func openActivityMonitor() {
        closeDashboard()
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func tooltip(for snapshot: SystemSnapshot) -> String {
        [
            "CPU \(Format.percent(snapshot.cpu.usage))",
            "GPU \(Format.percent(snapshot.gpu.usage))",
            "内存 \(Format.bytes(snapshot.memory.used)) / \(Format.bytes(snapshot.memory.total))",
            "↓ \(Format.rate(snapshot.network.downloadRate))  ↑ \(Format.rate(snapshot.network.uploadRate))",
            "温度 \(Format.temperature(snapshot.thermal.headline, unit: settings.temperatureUnit))",
        ].joined(separator: "\n")
    }
}

/// NSMenuItem that runs a closure, avoiding a target/selector pair per item.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}
