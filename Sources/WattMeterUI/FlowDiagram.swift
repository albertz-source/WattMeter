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

    /// 系统分项 = 总功率 − 屏幕 − 接口
    private var system: Double { reading?.systemComponentW ?? 0 }

    private var adapterToLoadW: Double { reading?.adapterToLoadW ?? 0 }
    private var batteryToLoadW: Double { reading?.batteryToLoadW ?? 0 }
    private var chargeW: Double { reading?.chargeW ?? 0 }

    /// 电池在给整机供电（含混合供电、纯电池）
    private var batterySupplying: Bool { hasBattery && batteryToLoadW > 0.05 }
    /// 电池正在被充电
    private var batteryCharging: Bool { hasBattery && onAC && chargeW > 0.05 }
    /// 接了电源、电池既不充也不放（已充满 / 待机）
    private var batteryIdle: Bool { hasBattery && !batterySupplying && !batteryCharging }
    private var hybrid: Bool { onAC && batterySupplying }

    /// 电池对外/对内功率（用于节点读数和支路判断）
    private var batteryFlowW: Double {
        if batteryCharging { return chargeW }
        if batterySupplying { return max(batteryToLoadW, abs(batteryPower ?? 0)) }
        return abs(batteryPower ?? 0)
    }

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

    // 左侧两个端口（电源在上、电池在下）的中心 y
    private let adapterY: CGFloat = 52
    private let batteryY: CGFloat = 128
    private let centerY: CGFloat = 94

    // MARK: - 连线

    private func link(from: CGPoint, to: CGPoint, watts: Double?, tint: Color,
                      muted: Bool = false, flowing: Bool = true) -> some View {
        let width: CGFloat = 14
        return ZStack {
            FlowLinkPath(start: from, end: to)
                .stroke(tint.opacity(muted ? 0.05 : 0.13),
                        style: StrokeStyle(lineWidth: width + 8, lineCap: .round))
                .blur(radius: 6)

            FlowLinkPath(start: from, end: to)
                .stroke(
                    LinearGradient(
                        colors: [tint.opacity(muted ? 0.06 : 0.34),
                                 tint.opacity(muted ? 0.03 : 0.09)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: width, lineCap: .round)
                )

            FlowLinkPath(start: from, end: to)
                .stroke(tint.opacity(muted ? 0.12 : 0.38),
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
                // dashPhase 递减才是沿路径前进；路径方向即能量方向
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
            .fill(LinearGradient(colors: [tint.opacity(muted ? 0.12 : 0.30), .white.opacity(0.03)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(muted ? 0.14 : 0.32), lineWidth: 0.8))
            .shadow(color: tint.opacity(muted ? 0.03 : 0.10), radius: 9, y: 2)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(tint.opacity(muted ? 0.55 : 1))
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
                .foregroundStyle(.white.opacity(muted ? 0.5 : 0.94))
            Text(name)
                .font(.system(size: 9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 104)
                .foregroundStyle(tint.opacity(muted ? 0.55 : 0.82))
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
        .help(L("左为供电源，中间为整机，右侧为系统 / 屏幕 / 接口的功率分配；流线圆点指示能量方向。"))
    }

    // MARK: 所有连线（在节点之下）

    private var links: some View {
        ZStack {
            if hasBattery {
                if onAC {
                    // 电源在上、电池在下，两条端口都常驻
                    link(from: CGPoint(x: leftNodeX + leftNodeWidth, y: adapterY),
                         to: CGPoint(x: centerNodeX, y: 78),
                         watts: max(total, adapterToLoadW), tint: Palette.mint)

                    if batteryCharging {
                        // 充电：能量从整机流向电池（路径方向 = 能量方向）
                        link(from: CGPoint(x: centerNodeX, y: 112),
                             to: CGPoint(x: leftNodeX + leftNodeWidth, y: batteryY),
                             watts: chargeW, tint: batteryTint)
                    } else if batterySupplying {
                        link(from: CGPoint(x: leftNodeX + leftNodeWidth, y: batteryY),
                             to: CGPoint(x: centerNodeX, y: 112),
                             watts: batteryFlowW, tint: batteryTint)
                    } else {
                        // 已充满 / 待机：保留一条淡线表示连接，但无流动
                        link(from: CGPoint(x: leftNodeX + leftNodeWidth, y: batteryY),
                             to: CGPoint(x: centerNodeX, y: 112),
                             watts: 0, tint: batteryTint, muted: true, flowing: false)
                    }
                } else {
                    // 纯电池供电：电池是唯一来源
                    link(from: CGPoint(x: leftNodeX + leftNodeWidth, y: centerY),
                         to: CGPoint(x: centerNodeX, y: centerY),
                         watts: max(total, batteryFlowW), tint: batteryTint)
                }
            } else {
                // 台式机：只有电源
                link(from: CGPoint(x: leftNodeX + leftNodeWidth, y: centerY),
                     to: CGPoint(x: centerNodeX, y: centerY),
                     watts: max(total, adapterToLoadW), tint: Palette.mint)
            }

            // 右侧：系统 / 屏幕 / 接口（始终三支）
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
        .frame(width: 364, height: 180)
    }

    // MARK: 所有节点与标签

    private var nodes: some View {
        ZStack {
            leftPorts
            centerNode
            rightBranches
        }
        .frame(width: 364, height: 180)
    }

    /// 左列：装上电池后，电源与电池两个端口常驻（纯电池时只显示电池）
    @ViewBuilder
    private var leftPorts: some View {
        if hasBattery {
            if onAC {
                // 上：电源适配器
                node("powerplug.fill", Palette.mint, leftNodeX, adapterY, 64)
                label(wattsText(max(adapterToLoadW, adapterInput ?? 0)),
                      L("电源输入 →"), Palette.mint, 96, adapterY,
                      detail: reading?.inputRailsText)

                // 下：电池（始终存在）
                node("battery.100percent", batteryTint, leftNodeX, batteryY, 64)
                label(wattsText(batteryFlowW), batteryName, batteryTint, 96, batteryY,
                      detail: batteryDetail)
            } else {
                node("battery.100percent", batteryTint, leftNodeX, centerY, 84)
                label(wattsText(max(batteryFlowW, batteryToLoadW)), L("电池供电 →"),
                      batteryTint, 96, centerY, detail: L("放电中"))
            }
        } else {
            node("powerplug.fill", Palette.mint, leftNodeX, centerY, 84)
            label(wattsText(max(total, adapterToLoadW)), L("电源输入 →"), Palette.mint,
                  96, centerY, detail: reading?.inputRailsText)
        }
    }

    private var batteryName: String {
        if batteryCharging { return L("电池充电 ←") }
        if batterySupplying { return L("电池辅助 →") }
        return L("电池待机")
    }

    private var batteryDetail: String? {
        if batteryCharging { return L("充电中") }
        if batterySupplying { return L("放电中") }
        if let percent = reading?.batteryPercent {
            return String(format: "%.0f%%", percent)
        }
        return nil
    }

    private var centerNode: some View {
        Group {
            node("laptopcomputer", .white.opacity(0.85), centerNodeX, centerY, 112)
            Text(PowerFormat.watts(total))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .position(x: centerNodeX + 20, y: 121)
            Text(L("整机 W"))
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.45))
                .position(x: centerNodeX + 20, y: 136)
        }
    }

    @ViewBuilder
    private var rightBranches: some View {
        node("cpu", systemTint, rightNodeX, 34, 50)
        label(wattsText(system), L("系统"), systemTint, 261, 34)

        node("display", displayTint, rightNodeX, 106, 34, muted: display == nil)
        label(wattsText(display), L("屏幕"), displayTint, 261, 106, muted: display == nil)

        node("cable.connector", portTint, rightNodeX, 160, 34, muted: ports == nil)
        label(wattsText(ports), L("接口"), portTint, 261, 160, muted: ports == nil)
    }
}
