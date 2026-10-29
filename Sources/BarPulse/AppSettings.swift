import AppKit
import BarPulseCore
import Foundation
import Observation
import ServiceManagement

@Observable
@MainActor
final class AppSettings {
    enum Layout: String, CaseIterable, Identifiable {
        case stacked
        case inline

        var id: String { rawValue }
        var title: String { self == .stacked ? "双行紧凑" : "单行图标" }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }

        /// `nil` inherits the system appearance.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    private enum Key {
        static let hidden = "hiddenMetrics"
        static let layout = "layout"
        static let colorful = "colorful"
        static let interval = "refreshInterval"
        static let unit = "temperatureUnit"
        static let appearance = "appearance"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any persisted value changes.
    @ObservationIgnored var onChange: (() -> Void)?

    var hiddenMetrics: Set<Metric> {
        didSet { defaults.set(hiddenMetrics.map(\.rawValue).sorted(), forKey: Key.hidden); onChange?() }
    }
    var layout: Layout {
        didSet { defaults.set(layout.rawValue, forKey: Key.layout); onChange?() }
    }
    var colorful: Bool {
        didSet { defaults.set(colorful, forKey: Key.colorful); onChange?() }
    }
    var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Key.interval); onChange?() }
    }
    var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Key.unit); onChange?() }
    }
    /// Applies to the dashboard and settings window; the menu bar item always follows the menu bar.
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance); onChange?() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenMetrics = Set((defaults.stringArray(forKey: Key.hidden) ?? []).compactMap(Metric.init(rawValue:)))
        layout = defaults.string(forKey: Key.layout).flatMap(Layout.init(rawValue:)) ?? .stacked
        colorful = defaults.object(forKey: Key.colorful) as? Bool ?? true
        let interval = defaults.double(forKey: Key.interval)
        refreshInterval = interval > 0 ? interval : 1
        temperatureUnit = defaults.string(forKey: Key.unit).flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    var visibleMetrics: [Metric] {
        Metric.allCases.filter { !hiddenMetrics.contains($0) }
    }

    func isVisible(_ metric: Metric) -> Bool {
        !hiddenMetrics.contains(metric)
    }

    func setVisible(_ metric: Metric, _ visible: Bool) {
        if visible {
            hiddenMetrics.remove(metric)
        } else if visibleMetrics.count > 1 {
            // Keep at least one metric so the status item never collapses to nothing.
            hiddenMetrics.insert(metric)
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("BarPulse: launch at login update failed: \(error.localizedDescription)")
            }
        }
    }
}
