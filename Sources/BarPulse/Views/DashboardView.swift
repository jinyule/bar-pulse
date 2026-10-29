import AppKit
import BarPulseCore
import SwiftUI

struct DashboardActions {
    var openActivityMonitor: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
}

struct DashboardView: View {
    let store: MetricsStore
    let settings: AppSettings
    let actions: DashboardActions

    private var snapshot: SystemSnapshot { store.snapshot }
    private var info: SystemInfo { store.info }
    private var unit: TemperatureUnit { settings.temperatureUnit }

    var body: some View {
        VStack(spacing: 12) {
            header
            HStack(alignment: .top, spacing: 12) {
                cpuCard
                gpuCard
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                memoryCard
                networkCard
            }
            .fixedSize(horizontal: false, vertical: true)
            thermalCard
            footer
        }
        .padding(16)
        .frame(width: 660)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [.cpu, .gpu], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
                .shadow(color: .gpu.opacity(0.35), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("BarPulse")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(machineSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Label("已运行 \(Format.duration(snapshot.date.timeIntervalSince(info.bootDate)))", systemImage: "clock")
                    .font(.system(size: 11, weight: .medium))
                Text(info.osVersion)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }

    private var machineSummary: String {
        var parts = [info.chip, "\(info.cpuCores) 核 CPU"]
        if let gpuCores = info.gpuCores { parts.append("\(gpuCores) 核 GPU") }
        parts.append("\(Format.bytes(info.memory)) 统一内存")
        return parts.joined(separator: " · ")
    }

    // MARK: - CPU

    private var cpuCard: some View {
        let cpu = snapshot.cpu
        return Card {
            CardHeader(symbol: "cpu", tint: Theme.cpu, title: "CPU",
                       subtitle: "负载 " + cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " · "),
                       value: Format.percent(cpu.usage))
            AreaChart(series: [
                ChartSeries(values: store.cpu.values, color: .cpu),
                ChartSeries(values: store.cpuSystem.values, color: .cpuAlt, filled: false, lineWidth: 1.1),
            ])
            .frame(height: 70)
            CoreGrid(cores: cpu.cores, clusters: info.clusters)
            HStack {
                StatItem(title: "用户", value: Format.precisePercent(cpu.user), dot: .cpu)
                StatItem(title: "系统", value: Format.precisePercent(cpu.system), dot: .cpuAlt)
                StatItem(title: "空闲", value: Format.precisePercent(1 - cpu.usage))
            }
        }
    }

    // MARK: - GPU

    private var gpuCard: some View {
        let gpu = snapshot.gpu
        return Card {
            CardHeader(symbol: "cube.transparent", tint: Theme.gpu, title: "GPU",
                       subtitle: [info.gpuCores.map { "\($0) 核" }, "Metal"].compactMap { $0 }.joined(separator: " · "),
                       value: gpu.available ? Format.percent(gpu.usage) : "--")
            AreaChart(series: [ChartSeries(values: store.gpu.values, color: .gpu)])
                .frame(minHeight: 70, maxHeight: .infinity)
            MeterRow(title: "渲染器", fraction: gpu.renderer, color: .gpu)
            MeterRow(title: "拼贴器 (Tiler)", fraction: gpu.tiler, color: .gpu)
            HStack {
                StatItem(title: "显存占用", value: gpu.memoryInUse.map(Format.bytes) ?? "--")
                StatItem(title: "90 秒峰值", value: Format.percent(store.gpu.peak))
            }
        }
    }

    // MARK: - Memory

    private var memoryCard: some View {
        let memory = snapshot.memory
        return Card {
            CardHeader(symbol: "memorychip", tint: Theme.memory, title: "内存",
                       subtitle: "\(Format.bytes(memory.total)) 统一内存",
                       value: Format.percent(memory.usage))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.bytes(memory.used))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("已使用")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Chip(text: "压力 \(memory.pressure.displayName)", color: pressureColor(memory.pressure))
            }
            SegmentBar(segments: [
                .init(id: "app", value: Double(memory.app), color: .memory),
                .init(id: "wired", value: Double(memory.wired), color: .wired),
                .init(id: "compressed", value: Double(memory.compressed), color: .compressed),
                .init(id: "cached", value: Double(memory.cached), color: .primary.opacity(0.22)),
            ], total: Double(memory.total))
            Grid(horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    LegendItem(title: "应用内存", value: Format.bytes(memory.app), color: .memory)
                    LegendItem(title: "联动内存", value: Format.bytes(memory.wired), color: .wired)
                }
                GridRow {
                    LegendItem(title: "被压缩", value: Format.bytes(memory.compressed), color: .compressed)
                    LegendItem(title: "已缓存文件", value: Format.bytes(memory.cached), color: .primary.opacity(0.3))
                }
            }
            Spacer(minLength: 0)
            HStack {
                StatItem(title: "可用", value: Format.bytes(memory.free))
                StatItem(title: "交换", value: "\(Format.bytes(memory.swapUsed)) / \(Format.bytes(memory.swapTotal))")
            }
        }
    }

    private func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return .memory
        case .warning: return .wired
        case .critical: return .red
        }
    }

    // MARK: - Network

    private var networkCard: some View {
        let network = snapshot.network
        let interface = [network.interfaceDisplayName, network.interface].compactMap { $0 }.joined(separator: " · ")
        return Card {
            CardHeader(symbol: "network", tint: Theme.download, title: "网络",
                       subtitle: interface.isEmpty ? "未连接" : interface)
            HStack(spacing: 0) {
                rateBlock(title: "下载", symbol: "arrow.down", rate: network.downloadRate, color: .download)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5, height: 30)
                    .padding(.horizontal, 12)
                rateBlock(title: "上传", symbol: "arrow.up", rate: network.uploadRate, color: .upload)
            }
            MirrorChart(download: store.download.values, upload: store.upload.values)
                .frame(minHeight: 64, maxHeight: .infinity)
            HStack {
                StatItem(title: "本机 IP", value: network.localAddress ?? "--")
                StatItem(title: "本次下载", value: Format.bytes(network.sessionDownloaded), dot: .download)
                StatItem(title: "本次上传", value: Format.bytes(network.sessionUploaded), dot: .upload)
            }
        }
    }

    private func rateBlock(title: String, symbol: String, rate: Double, color: Color) -> some View {
        let parts = Format.rateParts(rate)
        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(parts.value)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(parts.unit)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Thermal

    private var thermalCard: some View {
        let thermal = snapshot.thermal
        let headline = thermal.headline
        return Card {
            HStack(alignment: .center, spacing: 9) {
                CardHeader(symbol: "thermometer.medium", tint: Theme.thermal, title: "温度与风扇",
                           subtitle: thermal.cpuPeak.map { "CPU 最热核心 \(Format.temperature($0, unit: unit))" } ?? "SoC 传感器",
                           value: nil)
                Chip(text: "热状态 \(thermal.level.displayName)", color: thermalColor(thermal.level), symbol: "flame.fill")
                Text(Format.temperature(headline, unit: unit))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    // Only tint when it's a warning; yellow-green digits read poorly on light glass.
                    .foregroundStyle(headline.map { $0 >= 75 ? Color.heat($0) : .primary } ?? .primary)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    AreaChart(series: [
                        ChartSeries(values: store.cpuTemperature.values, color: .thermal),
                        ChartSeries(values: store.gpuTemperature.values, color: .gpu, filled: false, lineWidth: 1.3),
                    ], range: 25...105)
                    .frame(height: 96)
                    HStack(spacing: 12) {
                        legendDot("CPU", .thermal)
                        legendDot("GPU", .gpu)
                        Spacer()
                        Text("25–105°C")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 236)
                VStack(spacing: 8) {
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            SensorTile(title: "CPU", celsius: thermal.cpu, unit: unit)
                            SensorTile(title: "GPU", celsius: thermal.gpu, unit: unit)
                            SensorTile(title: "内存", celsius: thermal.memory, unit: unit)
                        }
                        GridRow {
                            SensorTile(title: "SoC 晶粒", celsius: thermal.soc, unit: unit)
                            SensorTile(title: "SSD", celsius: thermal.ssd, unit: unit)
                            SensorTile(title: "电池", celsius: thermal.battery, unit: unit)
                        }
                    }
                    if !thermal.fans.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(thermal.fans) { FanTile(fan: $0) }
                        }
                    }
                }
            }
        }
    }

    private func legendDot(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(title)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func thermalColor(_ level: ThermalLevel) -> Color {
        switch level {
        case .nominal: return .memory
        case .fair: return .wired
        case .serious: return .upload
        case .critical: return .red
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            LiveDot(tick: store.sampleCount)
            Text("实时监控 · 每 \(intervalText) 刷新")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            FooterButton(title: "活动监视器", symbol: "chart.bar.xaxis", action: actions.openActivityMonitor)
            FooterButton(title: "设置", symbol: "gearshape", action: actions.openSettings)
            FooterButton(title: "退出", symbol: "power", action: actions.quit)
        }
        .padding(.horizontal, 2)
    }

    private var intervalText: String {
        let interval = settings.refreshInterval
        return interval == interval.rounded() ? "\(Int(interval)) 秒" : String(format: "%.1f 秒", interval)
    }
}
