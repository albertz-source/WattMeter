import SwiftUI
import WattMeterCore

/// 功率流向图。
///
/// 构图参考 PowerLens：左侧供电源 → 中间整机 → 右侧多条分支配电。
/// 连线用圆角贝塞尔流线（Sankey 风格）：渐变 + 辉光 + 沿路径流动的光点。
struct FlowLinkPath: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = end.x - start.x
        let c1 = CGPoint(x: start.x + dx * 0.45, y: start.y)
        let c2 = CGPoint(x: start.x + dx * 0.55, y: end.y)
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        return path
    }
}

public struct FlowDiagram: View {
    let reading: PowerReading?
    @ObservedObject private var l10n = Localization.shared

    public init(reading: PowerReading?) {
        self.reading = reading
    }

    // MARK: - 数据

    private var total: Double { reading?.totalW ?? 0 }
    private var hasBattery: Bool { reading?.hasBattery ?? false }
    private var onAC: Bool { reading?.onAC ?? true }
    private var adapterInput: Double? { reading?.adapterInputW }
    private var batteryPower: Double? { reading?.batteryPowerW }
    private var display: Double? { reading?.displayPowerW }
    private var ports: Double? { reading?.portPowerW }

    /// 系统分项 = 总功率 − 屏幕 − 接口（和 PowerLens 的估算口径一致）
    private var system: Double { reading?.systemComponentW ?? 0 }

    private var charging: Bool { hasBattery && onAC && (batteryPower ?? 0) > 0.05 }
    private var standby: Bool { hasBattery && onAC && abs(batteryPower ?? 0) <= 0.05 }
    private var discharging: Bool { hasBattery && (batteryPower ?? 0) < -0.05 }
    private var hybrid: Bool { onAC && discharging }

    private let systemTint = Palette.blue
    private let displayTint = Palette.purple
    private let portTint = Color.white.opacity(0.45)
    private let batteryTint = Palette.amber

    // 画布坐标（364 × 180）
    private let leftNodeX: CGFloat = 0
    private let leftNodeWidth: CGFloat = 40
    private let centerNodeX: CGFloat = 159
    private let centerNodeWidth: CGFloat = 40
    private let rightNodeX: CGFloat = 324
    private let rightNodeWidth: CGFloat = 40

    // MARK: - 连线

    /// 一条流线：辉光 + 渐变主体 + 描边 + 流动光点
    /// 流线宽度固定，不随功率数值变化（避免读数跳动时线宽抖动）
    private let flowWidth: CGFloat = 14

    private func link(from: CGPoint, to: CGPoint, watts: Double?, tint: Color,
                      muted: Bool = false, flowing: Bool = true) -> some View {
        let width = flowWidth
        return ZStack {
            FlowLinkPath(start: from, end: to)
                .stroke(tint.opacity(muted ? 0.04 : 0.13),
                        style: StrokeStyle(lineWidth: width + 8, lineCap: .round))
                .blur(radius: 6)

            FlowLinkPath(start: from, end: to)
                .stroke(
                    LinearGradient(
                        colors: [tint.opacity(muted ? 0.05 : 0.34),
                                 tint.opacity(muted ? 0.02 : 0.09)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: width, lineCap: .round)
                )

            FlowLinkPath(start: from, end: to)
                .stroke(tint.opacity(muted ? 0.10 : 0.38),
                        style: StrokeStyle(lineWidth: 0.8, lineCap: .round))

            if flowing && !muted, (watts ?? 0) > 0.05 {
                flowingDots(from: from, to: to, tint: tint)
            }
        }
    }

    @ViewBuilder
    private func flowingDots(from: CGPoint, to: CGPoint, tint: Color) -> some View {
        if RenderSettings.isPreviewing {
            FlowLinkPath(start: from, end: to)
                .stroke(Color.white.opacity(0.30),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                           dash: [2, 13], dashPhase: 0))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { context in
                // dashPhase 递增会让虚线反向（右→左）移动，这里取负值让光点顺着
                // 路径从电源端流向负载端。
                let phase = -CGFloat(context.date.timeIntervalSinceReferenceDate * 36)
                    .truncatingRemainder(dividingBy: 15)
                FlowLinkPath(start: from, end: to)
                    .stroke(tint.opacity(0.9),
                            style: StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                               dash: [2, 13], dashPhase: phase))
            }
        }
    }

    // MARK: - 节点 / 标签

    private func node(_ icon: String, _ tint: Color, _ x: CGFloat, _ y: CGFloat,
                      _ height: CGFloat, muted: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(muted ? 0.10 : 0.26), .white.opacity(0.03)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(muted ? 0.12 : 0.28), lineWidth: 0.8))
            .shadow(color: tint.opacity(muted ? 0.03 : 0.10), radius: 9, y: 2)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(tint.opacity(muted ? 0.5 : 1))
            )
            .frame(width: 40, height: height)
            .position(x: x + 20, y: y)
    }

    private func label(_ value: String, _ name: String, _ tint: Color,
                       _ x: CGFloat, _ y: CGFloat, muted: Bool = false,
                       detail: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(muted ? 0.42 : 0.94))
            Text(name)
                .font(.system(size: 9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 104)
                .foregroundStyle(tint.opacity(muted ? 0.42 : 0.82))
            if let detail {
                Text(detail)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
        }
        .position(x: x, y: y)
    }

    private func wattsText(_ value: Double?) -> String {
        value.map { PowerFormat.watts($0) + " W" } ?? "—"
    }

    // MARK: - 主体

    public var body: some View {
        ZStack {
            links
            nodes
        }
        .frame(width: 364, height: 180)
        .help(L("左为供电源，中间为整机，右侧为系统 / 屏幕 / 接口 / 电池的功率分配；流线圆点指示能量方向。"))
    }

    // 所有连线（在所有节点之下）
    private var links: some View {
        ZStack {
            if onAC, let input = adapterInput {
                let leftY: CGFloat = hybrid ? 116 : 94
                link(from: CGPoint(x: leftNodeX + leftNodeWidth, y: leftY),
                     to: CGPoint(x: centerNodeX, y: 94),
                     watts: total, tint: Palette.mint)
            } else if hasBattery, discharging {
                link(from: CGPoint(x: leftNodeX + leftNodeWidth, y: 94),
                     to: CGPoint(x: centerNodeX, y: 94),
                     watts: total, tint: batteryTint)
            }

            if hybrid {
                link(from: CGPoint(x: leftNodeX + leftNodeWidth, y: 20),
                     to: CGPoint(x: centerNodeX, y: 46),
                     watts: batteryPower.map { abs($0) }, tint: batteryTint)
            }

            if onAC {
                link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: 52),
                     to: CGPoint(x: rightNodeX, y: 24),
                     watts: system, tint: systemTint)
                link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: 78),
                     to: CGPoint(x: rightNodeX, y: 70),
                     watts: display, tint: displayTint, muted: display == nil)
                link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: 104),
                     to: CGPoint(x: rightNodeX, y: 115),
                     watts: ports, tint: portTint, muted: ports == nil)
                if charging {
                    link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: 130),
                         to: CGPoint(x: rightNodeX, y: 160),
                         watts: batteryPower, tint: batteryTint)
                } else {
                    link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: 130),
                         to: CGPoint(x: rightNodeX, y: 160),
                         watts: nil, tint: batteryTint, muted: true, flowing: false)
                }
            } else {
                link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: 62),
                     to: CGPoint(x: rightNodeX, y: 34),
                     watts: system, tint: systemTint)
                link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: 104),
                     to: CGPoint(x: rightNodeX, y: 106),
                     watts: display, tint: displayTint, muted: display == nil)
                link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: 138),
                     to: CGPoint(x: rightNodeX, y: 160),
                     watts: ports, tint: portTint, muted: ports == nil)
            }
        }
        .frame(width: 364, height: 180)
    }

    // 所有节点与标签
    private var nodes: some View {
        ZStack {
            // 左侧供电源
            if onAC {
                node("powerplug.fill", Palette.mint, leftNodeX, hybrid ? 116 : 94, 84)
                label(wattsText(adapterInput), L("电源输入 →"), Palette.mint,
                      96, hybrid ? 116 : 94,
                      detail: reading?.inputRailsText)
            } else if hasBattery {
                node("battery.100percent", batteryTint, leftNodeX, 94, 84)
                label(wattsText(batteryPower.map { abs($0) }), L("电池供电 →"), batteryTint, 96, 94)
            } else {
                node("powerplug.fill", Color.white.opacity(0.4), leftNodeX, 94, 84, muted: true)
                label("—", L("等待数据 →"), Color.white.opacity(0.4), 96, 94, muted: true)
            }

            if hybrid {
                node("battery.100percent", batteryTint, leftNodeX, 20, 32)
                label(wattsText(batteryPower.map { abs($0) }), L("电池辅助 →"), batteryTint, 97, 24)
            }

            // 中央整机
            node("laptopcomputer", .white.opacity(0.85), centerNodeX, 94, 112)
            Text(PowerFormat.watts(total))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .position(x: centerNodeX + 20, y: 121)
            Text(L("整机 W"))
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.45))
                .position(x: centerNodeX + 20, y: 136)

            // 右侧分支
            if onAC {
                node("cpu", systemTint, rightNodeX, 24, 40)
                label(wattsText(system), L("系统"), systemTint, 261, 24)

                node("display", displayTint, rightNodeX, 70, 32, muted: display == nil)
                label(wattsText(display), L("屏幕"), displayTint, 261, 70, muted: display == nil)

                node("cable.connector", portTint, rightNodeX, 115, 32, muted: ports == nil)
                label(wattsText(ports), L("接口"), portTint, 261, 115, muted: ports == nil)

                batteryNode
            } else {
                node("cpu", systemTint, rightNodeX, 34, 50)
                label(wattsText(system), L("系统"), systemTint, 261, 34)

                node("display", displayTint, rightNodeX, 106, 34, muted: display == nil)
                label(wattsText(display), L("屏幕"), displayTint, 261, 106, muted: display == nil)

                node("cable.connector", portTint, rightNodeX, 160, 34, muted: ports == nil)
                label(wattsText(ports), L("接口"), portTint, 261, 160, muted: ports == nil)
            }
        }
        .frame(width: 364, height: 180)
    }

    @ViewBuilder
    private var batteryNode: some View {
        if charging {
            node("battery.100percent", batteryTint, rightNodeX, 160, 32)
            label(wattsText(batteryPower), L("电池充电 →"), batteryTint, 261, 160)
        } else if hasBattery {
            node("battery.100percent", batteryTint.opacity(0.7), rightNodeX, 160, 32, muted: true)
            label(standby ? "0.0 W" : "—", L("电池待机"), batteryTint, 261, 160, muted: true)
        } else {
            node("battery.0percent", Color.white.opacity(0.4), rightNodeX, 160, 32, muted: true)
            label("—", L("无内置电池"), Color.white.opacity(0.4), 261, 160, muted: true)
        }
    }
}
