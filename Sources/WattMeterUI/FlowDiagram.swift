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
    private var cpuPower: Double? { reading?.cpuPowerW }
    private var gpuPower: Double? { reading?.gpuPowerW }
    private var anePower: Double? { reading?.anePowerW }

    /// 当前能拿到的芯片分项（拿不到的整项隐藏）
    private var chipItems: [(name: String, watts: Double)] {
        [("CPU", cpuPower), ("GPU", gpuPower), ("ANE", anePower)]
            .compactMap { item in
                guard let w = item.1 else { return nil }
                return (item.0, w)
            }
    }

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
    private let systemNodeX: CGFloat = 236
    private let systemNodeW: CGFloat = 34
    private let chipNodeX: CGFloat = 306
    private let chipNodeW: CGFloat = 34

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

    /// 小方块节点：内部显示「标题 + 数值」
    private func chipNode(_ title: String, _ value: String, tint: Color,
                          center: CGPoint, size: CGSize, muted: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(muted ? 0.10 : 0.24), .white.opacity(0.03)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(muted ? 0.12 : 0.28), lineWidth: 0.7))
            .overlay(
                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(tint.opacity(muted ? 0.55 : 0.9))
                    Text(value)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(muted ? 0.45 : 0.92))
                }
            )
            .frame(width: size.width, height: size.height)
            .position(center)
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
                         to: CGPoint(x: centerNodeX, y: centerY),
                         watts: max(total, adapterToLoadW), tint: Palette.mint)

                    if batteryCharging {
                        // 充电：能量从整机流向电池（路径方向 = 能量方向）
                        link(from: CGPoint(x: centerNodeX, y: centerY),
                             to: CGPoint(x: leftNodeX + leftNodeWidth, y: batteryY),
                             watts: chargeW, tint: batteryTint)
                    } else if batterySupplying {
                        link(from: CGPoint(x: leftNodeX + leftNodeWidth, y: batteryY),
                             to: CGPoint(x: centerNodeX, y: centerY),
                             watts: batteryFlowW, tint: batteryTint)
                    } else {
                        // 已充满 / 待机：保留一条淡线表示连接，但无流动
                        link(from: CGPoint(x: leftNodeX + leftNodeWidth, y: batteryY),
                             to: CGPoint(x: centerNodeX, y: centerY),
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

            // 右侧：系统（再分 CPU / GPU / ANE） + 屏幕 / 接口
            let mainSystemX: CGFloat = chipItems.isEmpty ? rightNodeX : systemNodeX
            let mainSystemY: CGFloat = chipItems.isEmpty ? 34 : 62
            link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: centerY),
                 to: CGPoint(x: mainSystemX, y: mainSystemY),
                 watts: system, tint: systemTint)
            if !chipItems.isEmpty {
                ForEach(Array(chipItems.enumerated()), id: \.offset) { index, item in
                    link(from: CGPoint(x: systemNodeX + systemNodeW, y: 62),
                         to: CGPoint(x: chipNodeX, y: chipY(index, of: chipItems.count)),
                         watts: item.watts, tint: systemTint)
                }
            }
            let sideX: CGFloat = chipItems.isEmpty ? rightNodeX : systemNodeX
            link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: centerY),
                 to: CGPoint(x: sideX, y: 116),
                 watts: display, tint: displayTint, muted: display == nil)
            link(from: CGPoint(x: centerNodeX + centerNodeWidth, y: centerY),
                 to: CGPoint(x: sideX, y: 150),
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

    private func chipY(_ index: Int, of count: Int) -> CGFloat {
        let spacing: CGFloat = 34
        let middle = (Double(count) - 1) / 2
        return 62 + CGFloat(Double(index) - middle) * spacing
    }

    @ViewBuilder
    private var rightBranches: some View {
        if !chipItems.isEmpty {
            // 两列：系统 → CPU / GPU / ANE，另加屏幕 / 接口
            chipNode(L("系统"), PowerFormat.watts(system), tint: systemTint,
                     center: CGPoint(x: systemNodeX + systemNodeW / 2, y: 62),
                     size: CGSize(width: systemNodeW, height: 36))

            ForEach(Array(chipItems.enumerated()), id: \.offset) { index, item in
                chipNode(item.name, PowerFormat.watts(item.watts), tint: systemTint,
                         center: CGPoint(x: chipNodeX + chipNodeW / 2,
                                         y: chipY(index, of: chipItems.count)),
                         size: CGSize(width: chipNodeW, height: 20))
            }

            chipNode(L("屏幕"), PowerFormat.watts(display), tint: displayTint,
                     center: CGPoint(x: systemNodeX + systemNodeW / 2, y: 116),
                     size: CGSize(width: systemNodeW, height: 22), muted: display == nil)
            chipNode(L("接口"), PowerFormat.watts(ports), tint: portTint,
                     center: CGPoint(x: systemNodeX + systemNodeW / 2, y: 150),
                     size: CGSize(width: systemNodeW, height: 22), muted: ports == nil)
        } else {
            // 拿不到分项功率：回到三支布局
            chipNode(L("系统"), PowerFormat.watts(system), tint: systemTint,
                     center: CGPoint(x: rightNodeX + 17, y: 34),
                     size: CGSize(width: 34, height: 32))
            chipNode(L("屏幕"), PowerFormat.watts(display), tint: displayTint,
                     center: CGPoint(x: rightNodeX + 17, y: 106),
                     size: CGSize(width: 34, height: 26), muted: display == nil)
            chipNode(L("接口"), PowerFormat.watts(ports), tint: portTint,
                     center: CGPoint(x: rightNodeX + 17, y: 160),
                     size: CGSize(width: 34, height: 26), muted: ports == nil)
        }
    }
}
