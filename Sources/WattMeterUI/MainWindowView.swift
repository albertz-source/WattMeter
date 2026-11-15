import SwiftUI
import WattMeterCore

/// 主窗口：更大的流向图与图表，以及适配器 / 电池 / 温度侧栏。
public struct MainWindowView: View {
    @ObservedObject private var store: PowerStore
    @ObservedObject private var l10n = Localization.shared
    /// 窗口里使用可滚动容器；离屏预览时关闭（ScrollView 无法被 ImageRenderer 渲染）
    private let scrollable: Bool

    public init(store: PowerStore, scrollable: Bool = false) {
        self.store = store
        self.scrollable = scrollable
    }

    private var samples: [PowerReading] { store.readings(in: store.windowSeconds) }

    @ViewBuilder
    public var body: some View {
        if scrollable {
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .padding(18)
                    .frame(minWidth: 980)
            }
            .background(PanelBackground())
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .foregroundStyle(.white.opacity(0.9))
        } else {
            content
                .padding(18)
                .frame(minWidth: 980)
                .background(PanelBackground())
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 12) {
                    Card(title: L("功率流向")) {
                        FlowDiagram(reading: store.latest)
                            .frame(maxWidth: .infinity)
                    }
                    Card(title: L("功率来源随时间变化"), subtitle: localizedWindowLabel(store.windowSeconds)) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ChartLegend(items: [(L("电源"), Palette.mint), (L("电池"), Palette.amber)])
                                Spacer()
                                WindowPicker(
                                    options: [WindowOption(L("1 分钟"), 60),
                                              WindowOption(L("5 分钟"), 300),
                                              WindowOption(L("15 分钟"), 900),
                                              WindowOption(L("1 小时"), 3600)],
                                    selected: store.windowSeconds,
                                    onSelect: { store.setWindow($0) }
                                )
                            }
                            SourceAreaChart(readings: samples, height: 168)
                        }
                    }
                    Card(title: L("整机功耗 / 电池净功率")) {
                        PowerLineChart(readings: samples, height: 116)
                    }
                }
                .frame(maxWidth: .infinity)

                sidebar
                    .frame(width: 300)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: "bolt.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Palette.mint)
                        Text("WattMeter")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(L("macOS 功率监视器"))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Text(L("整机功耗 · 每 1 秒读取") + " · " + L(store.statusMessage))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(PowerFormat.watts(store.latest?.totalW))
                        .font(.system(size: 38, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text("W")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.mint)
                }
            }

            HStack(spacing: 6) {
                StateDot(color: stateColor)
                Text(store.latest.map { L($0.batteryStateText) } ?? L("等待数据"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if let latest = store.latest, latest.hasBattery {
                    BatteryGlyph(percent: latest.batteryPercent, charging: latest.isCharging)
                    Text(latest.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .monospacedDigit()
                    Text("· " + (latest.timeRemainingMinutes.map { localizedTimeRemaining($0) } ?? "—"))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    Text(L("无内置电池"))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .font(.system(size: 10))

            Text(L("峰值") + " " + PowerFormat.wattsWithUnit(store.peakW)
                 + " · " + L("平均") + " " + PowerFormat.wattsWithUnit(store.averageW)
                 + " · " + L("累计") + " " + String(format: "%.2f", store.sessionEnergyWh) + " Wh · " + L("每 1 秒采样"))
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var stateColor: Color {
        guard let latest = store.latest else { return Palette.muted }
        if !latest.hasBattery { return Palette.mint }
        if latest.isHybrid { return Palette.amber }
        if latest.isCharging { return Palette.charge }
        if latest.onAC { return Palette.mint }
        return Palette.amber
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            Card(title: L("适配器")) {
                VStack(spacing: 1) {
                    powerRow("powerplug.fill", L("DC 输入"), dcInputCaption,
                             PowerFormat.watts(store.latest?.adapterInputW), "W", Palette.mint)
                    Divider().opacity(0.18)
                    powerRow("cable.connector", L("额定功率"),
                             store.latest?.adapterName ?? L("未报告"),
                             PowerFormat.watts(store.latest?.adapterRatedW, digits: 0), "W", Palette.purple)
                    Divider().opacity(0.18)
                    powerRow("bolt.horizontal.fill", L("适配器损耗"), L("系统遥测估计"),
                             PowerFormat.watts(store.latest?.adapterLossW, digits: 2), "W", Palette.muted)
                    Divider().opacity(0.18)
                    powerRow("house", L("墙插估算"), L("DC 输入 + 损耗"),
                             PowerFormat.watts(store.latest?.wallPowerW), "W", Palette.purple)
                }
            }

            Card(title: L("电池")) {
                VStack(spacing: 1) {
                    powerRow("battery.100percent", L("状态"),
                             store.latest.map { L($0.batteryStateText) } ?? "—",
                             PowerFormat.watts(store.latest?.batteryPercent, digits: 0), "%", Palette.amber)
                    Divider().opacity(0.18)
                    powerRow("arrow.up.arrow.down", L("净功率"), L("正 = 充电，负 = 放电"),
                             signedWatts(store.latest?.batteryPowerW), "W", Palette.amber)
                    Divider().opacity(0.18)
                    powerRow("clock", L("剩余时间"), L("系统估计"),
                             localizedTimeRemaining(store.latest?.timeRemainingMinutes), nil, Palette.blue)
                    Divider().opacity(0.18)
                    powerRow("square.split.2x1", L("来源占比"), L("电源 / 电池"),
                             batteryShareText, nil, Palette.blue)
                }
            }

            Card(title: L("温度与散热")) {
                VStack(spacing: 1) {
                    powerRow("cpu", "CPU", L("Tp* 集群传感器最高"),
                             tempText(store.latest?.cpuTempC), "°C", Palette.blue)
                    Divider().opacity(0.18)
                    powerRow("display", "GPU", "Tg*",
                             tempText(store.latest?.gpuTempC), "°C", Palette.purple)
                    Divider().opacity(0.18)
                    powerRow("internaldrive", "SSD", "TH0*",
                             tempText(store.latest?.ssdTempC), "°C", Palette.mint)
                    Divider().opacity(0.18)
                    powerRow("battery.100percent", L("电池"), "TB0T",
                             tempText(store.latest?.batteryTempC), "°C", Palette.amber)
                    Divider().opacity(0.18)
                    powerRow("square.stack.3d.up", L("平台"), "Ts0P",
                             tempText(store.latest?.platformTempC), "°C", Palette.muted)
                    Divider().opacity(0.18)
                    powerRow("fan", L("风扇"), "SMC F0Ac", store.latest?.fanText ?? "—", "RPM", Palette.blue)
                }
            }

            Spacer(minLength: 0)

            Text(L("功率为系统内部测量值；墙插功率为估算值（DC 输入 + 适配器损耗），与插座功率计可能有 5–15% 差异。"))
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var batteryShareText: String {
        guard let latest = store.latest else { return "—" }
        return "\(Int((latest.adapterShare * 100).rounded()))% / \(Int((latest.batteryShare * 100).rounded()))%"
    }

    private var dcInputCaption: String {
        if let rails = store.latest?.inputRailsText {
            return rails
        }
        return store.latest.map { L($0.source.label) } ?? "—"
    }

    private func tempText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f", value)
    }

    private func powerRow(_ icon: String, _ title: String, _ caption: String,
                          _ value: String, _ unit: String?, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(caption)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                if let unit {
                    Text(unit)
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .fixedSize()
        }
        .frame(height: 32)
    }
}
