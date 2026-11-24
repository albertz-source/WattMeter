import SwiftUI
import WattMeterCore

/// 菜单栏弹出面板
public struct DashboardView: View {
    @ObservedObject private var store: PowerStore
    @ObservedObject private var loginItem: LoginItemController
    @ObservedObject private var l10n = Localization.shared
    private let onOpenWindow: () -> Void
    private let onShowAbout: () -> Void
    private let onQuit: () -> Void

    public init(store: PowerStore,
                loginItem: LoginItemController = LoginItemController(),
                onOpenWindow: @escaping () -> Void = {},
                onShowAbout: @escaping () -> Void = {},
                onQuit: @escaping () -> Void = {}) {
        self.store = store
        self.loginItem = loginItem
        self.onOpenWindow = onOpenWindow
        self.onShowAbout = onShowAbout
        self.onQuit = onQuit
    }

    private var samples: [PowerReading] { store.readings(in: store.windowSeconds) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            PowerHeader(reading: store.latest)
            FlowDiagram(reading: store.latest)
            SourceSplitBar(reading: store.latest)
            TempStrip(reading: store.latest)
            DiskStrip(reading: store.latest)
            trendCard
            rowsCard
            footerBar
        }
        .padding(14)
        .frame(width: 400)
        .background(PanelBackground())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white.opacity(0.9))
    }

    // MARK: - 趋势

    private var trendCard: some View {
        Card(title: L("功率趋势"), subtitle: localizedWindowLabel(store.windowSeconds)) {
            TrendSparkline(readings: samples, height: 54)
        }
    }

    // MARK: - 明细

    private var rowsCard: some View {
        let latest = store.latest
        return VStack(spacing: 1) {
            PowerRow(icon: "powerplug.fill",
                     title: L("适配器输入"),
                     caption: latest.map { L($0.source.label) } ?? "—",
                     value: PowerFormat.watts(latest?.adapterInputW),
                     unit: "W",
                     tint: Palette.mint)
            Divider().opacity(0.18)
            PowerRow(icon: "bolt.horizontal.fill",
                     title: L("墙插估算"),
                     caption: L("含适配器损耗"),
                     value: PowerFormat.watts(latest?.wallPowerW),
                     unit: "W",
                     tint: Palette.purple)
            Divider().opacity(0.18)
            PowerRow(icon: "battery.100percent",
                     title: L("电池净功率"),
                     caption: batteryCaption,
                     value: signedWatts(latest?.batteryPowerW),
                     unit: "W",
                     tint: Palette.amber)
            Divider().opacity(0.18)
            PowerRow(icon: "heart.text.square.fill",
                     title: L("电池健康"),
                     caption: batteryHealthCaption,
                     value: latest?.batteryHealthText ?? "—",
                     tint: Palette.amber)
            Divider().opacity(0.18)
            PowerRow(icon: "fan",
                     title: L("风扇转速"),
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
        guard let latest = store.latest, latest.fanRPM != nil else { return L("无风扇或不可读") }
        var parts: [String] = ["SMC"]
        if let count = latest.fanCount, count > 1 {
            parts.append("\(count) " + L("风扇"))
        }
        if latest.fanStopped {
            parts.append(L("已停转"))
        }
        if let min = latest.fanMinRPM, let max = latest.fanMaxRPM {
            parts.append(String(format: "%.0f–%.0f RPM", min, max))
        }
        return parts.joined(separator: " · ")
    }

    /// 电池健康行：满充 / 设计容量 + 循环次数
    private var batteryHealthCaption: String {
        guard let latest = store.latest else { return L("等待数据") }
        if !latest.hasBattery { return L("本机无内置电池") }
        guard latest.hasBatteryHealth else { return L("系统未提供容量数据") }
        var parts = [latest.batteryCapacityText]
        if let cycles = latest.batteryCycleCount {
            parts.append(localizedCycles(cycles))
        }
        return parts.joined(separator: " · ")
    }

    private var batteryCaption: String {
        guard let latest = store.latest else { return L("等待数据") }
        if !latest.hasBattery { return L("本机无内置电池") }
        let state = L(latest.batteryStateText)
        guard let minutes = latest.timeRemainingMinutes, minutes > 0 else { return state }
        return state + " · " + localizedTimeRemaining(minutes)
    }

    // MARK: - 底部

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("峰值") + " " + PowerFormat.wattsWithUnit(store.peakW))
                Text("·")
                Text(L("累计") + " " + String(format: "%.2f", store.sessionEnergyWh) + " Wh")
                if let rails = store.latest?.inputRailsText {
                    Text("·")
                    Text(L("输入") + " " + rails)
                }
                Spacer()
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(1)

            HStack(spacing: 10) {
                Button {
                    onOpenWindow()
                } label: {
                    Label(L("完整窗口"), systemImage: "macwindow")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.mint)

                Button {
                    if loginItem.requiresApproval {
                        loginItem.openSystemSettings()
                    } else {
                        loginItem.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: loginItem.enabled ? "checkmark.circle.fill" : "power.circle")
                            .font(.system(size: 10))
                        Text(L("开机启动")).font(.system(size: 10))
                        if loginItem.requiresApproval {
                            Text(L("待批准")).font(.system(size: 8)).opacity(0.7)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(loginItem.enabled
                                       ? Palette.mint.opacity(0.18)
                                       : Color.white.opacity(0.06))
                    )
                    .foregroundStyle(loginItem.enabled ? Palette.mint : Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help(L("登录时自动启动 WattMeter · ") + L(loginItem.statusDescription))

                Spacer()

                Button {
                    l10n.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe").font(.system(size: 10))
                        Text(l10n.language == .zh ? "EN" : "中").font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(L("关于语言"))

                Button {
                    onQuit()
                } label: {
                    Image(systemName: "power").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
                .help(L("退出 WattMeter"))
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
