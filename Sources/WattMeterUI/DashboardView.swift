import SwiftUI
import WattMeterCore

/// 菜单栏弹出面板
public struct DashboardView: View {
    @ObservedObject private var store: PowerStore
    private let onOpenWindow: () -> Void
    private let onQuit: () -> Void

    public init(store: PowerStore,
                onOpenWindow: @escaping () -> Void = {},
                onQuit: @escaping () -> Void = {}) {
        self.store = store
        self.onOpenWindow = onOpenWindow
        self.onQuit = onQuit
    }

    private var samples: [PowerReading] { store.readings(in: store.windowSeconds) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PowerHeader(reading: store.latest)
            FlowDiagram(reading: store.latest)
            SourceSplitBar(reading: store.latest)
            TempStrip(reading: store.latest)
            trendCard
            rowsCard
            footerBar
        }
        .padding(16)
        .frame(width: 400)
        .background(PanelBackground())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white.opacity(0.9))
    }

    // MARK: - 趋势

    private var trendCard: some View {
        Card(title: "功率趋势", subtitle: windowLabel) {
            TrendSparkline(readings: samples, height: 54)
        }
    }

    private var windowLabel: String {
        switch store.windowSeconds {
        case 60: return "最近 1 分钟"
        case 900: return "最近 15 分钟"
        default: return "最近 5 分钟"
        }
    }

    // MARK: - 明细

    private var rowsCard: some View {
        let latest = store.latest
        return VStack(spacing: 1) {
            PowerRow(icon: "powerplug.fill",
                     title: "适配器输入",
                     caption: latest?.source == .telemetry ? "DC 输入 · 系统遥测" : "DC 输入 · SMC 实时",
                     value: PowerFormat.watts(latest?.adapterInputW),
                     unit: "W",
                     tint: Palette.mint)
            Divider().opacity(0.18)
            PowerRow(icon: "bolt.horizontal.fill",
                     title: "墙插估算",
                     caption: "含适配器损耗",
                     value: PowerFormat.watts(latest?.wallPowerW),
                     unit: "W",
                     tint: Palette.purple)
            Divider().opacity(0.18)
            PowerRow(icon: "battery.100percent",
                     title: "电池净功率",
                     caption: batteryCaption,
                     value: signedWatts(latest?.batteryPowerW),
                     unit: "W",
                     tint: Palette.amber)
            Divider().opacity(0.18)
            PowerRow(icon: "fan",
                     title: "风扇转速",
                     caption: fanCaption,
                     value: latest?.fanText ?? "—",
                     unit: "RPM",
                     tint: Palette.blue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 0.7)
        )
    }

    private var fanCaption: String {
        guard let latest = store.latest, latest.fanRPM != nil else { return "无风扇或不可读" }
        if let min = latest.fanMinRPM, let max = latest.fanMaxRPM {
            return String(format: "SMC F0Ac · %.0f–%.0f RPM", min, max)
        }
        return "SMC F0Ac"
    }

    private var batteryCaption: String {
        guard let latest = store.latest else { return "等待数据" }
        if !latest.hasBattery { return "本机无内置电池" }
        if latest.isCharging { return "充电中 · \(latest.timeRemainingText)" }
        if !latest.onAC { return "放电中 · 剩余 \(latest.timeRemainingText)" }
        return latest.isCharged ? "已充满" : "外接电源 · 待机"
    }

    // MARK: - 底部

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("峰值 \(PowerFormat.wattsWithUnit(store.peakW))")
                Text("·")
                Text("累计 \(String(format: "%.2f", store.sessionEnergyWh)) Wh")
                Spacer()
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(1)

            HStack(spacing: 10) {
                Button {
                    onOpenWindow()
                } label: {
                    Label("完整窗口", systemImage: "macwindow")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.mint)

                Spacer()

                Button {
                    onQuit()
                } label: {
                    Image(systemName: "power").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
                .help("退出 WattMeter")
            }
        }
    }
}

// MARK: - 格式化辅助

public func signedWatts(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%+.1f", value)
}

public func percentText(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.0f", value)
}
