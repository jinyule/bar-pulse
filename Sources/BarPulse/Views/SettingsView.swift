import AppKit
import BarPulseCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricsStore
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                StatusBarPreview(model: previewModel)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            } header: {
                Text("菜单栏预览")
            }

            Section("菜单栏显示") {
                ForEach(Metric.allCases) { metric in
                    Toggle(isOn: Binding(
                        get: { settings.isVisible(metric) },
                        set: { settings.setVisible(metric, $0) }
                    )) {
                        Label {
                            Text(metric.title)
                        } icon: {
                            IconTile(symbol: metric.symbol, tint: Theme.color(for: metric), size: 20)
                        }
                    }
                }
                Picker("样式", selection: $settings.layout) {
                    ForEach(AppSettings.Layout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("彩色指示条", isOn: $settings.colorful)
            }

            Section {
                Picker("仪表盘外观", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("透明度") {
                    HStack {
                        Slider(value: $settings.dashboardTransparency, in: AppSettings.transparencyRange)
                            .labelsHidden()
                            .accessibilityLabel("透明度")
                        Text(Format.percent(settings.dashboardTransparency))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("面板大小") {
                    HStack {
                        Text(settings.dashboardSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "默认")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("恢复默认") { settings.dashboardSize = nil }
                            .disabled(settings.dashboardSize == nil)
                    }
                }
            } header: {
                Text("仪表盘")
            } footer: {
                Text("拖动仪表盘的左、右、下边缘或底部两角即可调整大小；透明度也可以在仪表盘底栏直接调节。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("通用") {
                Picker("刷新频率", selection: $settings.refreshInterval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("3 秒").tag(3.0)
                    Text("5 秒").tag(5.0)
                }
                Picker("温度单位", selection: $settings.temperatureUnit) {
                    Text("摄氏度 °C").tag(TemperatureUnit.celsius)
                    Text("华氏度 °F").tag(TemperatureUnit.fahrenheit)
                }
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        settings.launchAtLogin = newValue
                        launchAtLogin = settings.launchAtLogin
                    }
            }

            Section {
                HStack {
                    Text("BarPulse \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    Spacer()
                    Text("原生 Swift · AppKit + SwiftUI")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = settings.launchAtLogin }
    }

    private var previewModel: StatusBarModel {
        let snapshot = store.snapshot
        return StatusBarModel(
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
    }
}

/// Hosts the real menu bar renderer so the preview is pixel-identical to the status item.
struct StatusBarPreview: NSViewRepresentable {
    let model: StatusBarModel

    func makeNSView(context: Context) -> StatusBarView {
        let view = StatusBarView()
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    func updateNSView(_ view: StatusBarView, context: Context) {
        view.model = model
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: AppSettings
    private let store: MetricsStore

    init(settings: AppSettings, store: MetricsStore) {
        self.settings = settings
        self.store = store
        super.init()
    }

    /// Opens the window centred on `screen` (where the user just clicked), or the main screen.
    func show(on screen: NSScreen? = nil) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, store: store))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "BarPulse 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            if let area = screen?.visibleFrame {
                // Like center(): horizontally centred, a little above the middle.
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                              y: (area.minY + (area.height - size.height) * 2 / 3).rounded()))
            } else {
                window.center()
            }
            self.window = window
        }
        applyAppearance()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation is cooperative since macOS 14 and may be declined when the request
        // doesn't come from a click in our own UI; make sure the window still shows up.
        window?.orderFrontRegardless()
    }

    func applyAppearance() {
        window?.appearance = settings.appearance.nsAppearance
    }

    /// Like the dashboard, the settings UI only exists while it's on screen; a hidden window
    /// would otherwise keep re-rendering its live preview on every sample.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
