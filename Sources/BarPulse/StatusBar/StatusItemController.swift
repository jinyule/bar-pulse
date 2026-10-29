import AppKit
import BarPulseCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let barView = StatusBarView()
    private let popover = NSPopover()
    private let store: MetricsStore
    private let settings: AppSettings
    private let openSettings: () -> Void

    init(store: MetricsStore, settings: AppSettings, openSettings: @escaping () -> Void) {
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

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        refresh()
    }

    /// The dashboard is built on open and released on close, so a closed popover costs nothing:
    /// no SwiftUI graph updates, no animations, no backing stores. History lives in the store.
    private func makeDashboard() -> NSViewController {
        let dashboard = DashboardView(
            store: store,
            settings: settings,
            actions: DashboardActions(
                openActivityMonitor: { [weak self] in self?.openActivityMonitor() },
                openSettings: { [weak self] in
                    self?.closePopover()
                    self?.openSettings()
                },
                quit: { NSApp.terminate(nil) }
            )
        )
        let host = NSHostingController(rootView: dashboard)
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    /// Pushes the latest snapshot + settings into the menu bar view.
    func refresh() {
        let snapshot = store.snapshot
        let appearance = settings.appearance.nsAppearance
        if popover.appearance?.name != appearance?.name {
            popover.appearance = appearance
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

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        let content = makeDashboard()
        popover.contentViewController = content
        // Size before showing so the popover doesn't open at a default size and then jump.
        popover.contentSize = content.view.fittingSize
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        popover.contentViewController = nil
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        closePopover()
        let menu = NSMenu()
        menu.addItem(item("打开仪表盘", symbol: "gauge.with.dots.needle.67percent") { [weak self] in self?.showPopover() })
        menu.addItem(item("活动监视器", symbol: "chart.bar.xaxis") { [weak self] in self?.openActivityMonitor() })
        menu.addItem(.separator())
        menu.addItem(item("设置…", symbol: "gearshape", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(item("退出 BarPulse", symbol: "power", key: "q") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }

    private func item(_ title: String, symbol: String, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, handler: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func openActivityMonitor() {
        closePopover()
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
