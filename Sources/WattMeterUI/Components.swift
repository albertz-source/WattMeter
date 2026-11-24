import SwiftUI
import AppKit
import WattMeterCore

// MARK: - 渲染模式（离屏预览时替换毛玻璃背景）

public enum RenderSettings {
    /// 由 wattmeter-snapshot 在渲染前置为 true。
    /// NSVisualEffectView（毛玻璃）无法被 ImageRenderer 导出，预览时改用纯色底。
    public static var isPreviewing = false
}

// MARK: - 配色（参考 PowerLens 的深色强调色系）

public enum Palette {
    /// 主色：电源 / 正向数值
    public static let mint = Color(red: 0.43, green: 0.88, blue: 0.76)
    /// 电池放电 / 充电
    public static let amber = Color(red: 0.96, green: 0.76, blue: 0.45)
    /// 系统负载
    public static let blue = Color(red: 0.49, green: 0.69, blue: 0.98)
    /// 适配器 / 端口 / 次要强调
    public static let purple = Color(red: 0.73, green: 0.61, blue: 0.96)
    /// 充电绿
    public static let charge = Color(red: 0.43, green: 0.88, blue: 0.76)

    // 语义别名（图表和旧代码使用）
    public static let adapter = mint
    public static let battery = amber
    public static let muted = Color.white.opacity(0.45)
}

// MARK: - 深色毛玻璃背景

/// 采样窗口背后的系统材质；「降低透明度」等辅助功能设置仍由系统尊重。
public struct FrostedPanelBackground: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 面板统一背景：毛玻璃（预览时纯色）+ 深色渐变叠加
public struct PanelBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            if RenderSettings.isPreviewing {
                Color(red: 0.09, green: 0.11, blue: 0.13)
            } else {
                FrostedPanelBackground()
            }
            LinearGradient(
                colors: [
                    Color(red: 0.115, green: 0.13, blue: 0.15).opacity(0.22),
                    Color(red: 0.075, green: 0.085, blue: 0.10).opacity(0.35),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 卡片

public struct Card<Content: View>: View {
    let title: String?
    let subtitle: String?
    let content: Content

    public init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            content
        }
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 0.7)
        )
    }
}

// MARK: - 明细行（图标 + 标题/说明 + 右对齐读数）

public struct PowerRow: View {
    let icon: String
    let title: String
    let caption: String
    let value: String
    var unit: String?
    let tint: Color

    public init(icon: String, title: String, caption: String,
                value: String, unit: String? = nil, tint: Color) {
        self.icon = icon
        self.title = title
        self.caption = caption
        self.value = value
        self.unit = unit
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                if let unit {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .fixedSize()
        }
        .frame(height: 36)
    }
}

// MARK: - 状态点

public struct StateDot: View {
    let color: Color
    public init(color: Color) { self.color = color }
    public var body: some View {
        Circle().fill(color).frame(width: 4, height: 4)
    }
}

// MARK: - 电池图形

public struct BatteryGlyph: View {
    let percent: Double?
    let charging: Bool
    var tint: Color

    public init(percent: Double?, charging: Bool, tint: Color = Palette.mint) {
        self.percent = percent
        self.charging = charging
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5).stroke(tint.opacity(0.65), lineWidth: 1)
                if let percent {
                    RoundedRectangle(cornerRadius: 1.3)
                        .fill(tint)
                        .frame(width: 18 * CGFloat(min(100, max(0, percent))) / 100, height: 7)
                        .padding(.leading, 2)
                }
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(red: 0.08, green: 0.15, blue: 0.16))
                        .frame(width: 22, height: 11)
                }
            }
            .frame(width: 22, height: 11)
            RoundedRectangle(cornerRadius: 0.7)
                .fill(tint.opacity(0.65))
                .frame(width: 2, height: 4)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

// MARK: - 顶部大号读数

public struct PowerHeader: View {
    let reading: PowerReading?
    @ObservedObject private var l10n = Localization.shared

    public init(reading: PowerReading?) {
        self.reading = reading
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.circle.fill").foregroundStyle(Palette.mint)
                        Text("WattMeter").fontWeight(.semibold)
                    }
                    .font(.system(size: 13))
                    Text(L("整机功耗 · 每 1 秒读取"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(PowerFormat.watts(reading?.totalW))
                        .font(.system(size: 31, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("W")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.mint)
                }
            }

            HStack(spacing: 6) {
                StateDot(color: stateColor)
                Text(reading.map { L($0.batteryStateText) } ?? L("等待数据"))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if let reading {
                    BatteryGlyph(percent: reading.batteryPercent,
                                 charging: reading.isCharging,
                                 tint: reading.hasBattery ? Palette.mint : Palette.muted)
                    Text(reading.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10))
        }
    }

    private var stateColor: Color {
        guard let reading else { return Palette.muted }
        if !reading.hasBattery { return Palette.mint }
        if reading.isHybrid { return Palette.amber }
        if reading.isCharging { return Palette.charge }
        if reading.onAC { return Palette.mint }
        return Palette.amber
    }
}

// MARK: - 电源 / 电池 占比条

public struct SourceSplitBar: View {
    let reading: PowerReading?
    @ObservedObject private var l10n = Localization.shared

    public init(reading: PowerReading?) {
        self.reading = reading
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                legend(color: Palette.mint, title: L("电源"),
                       watts: reading?.adapterToLoadW,
                       percent: reading.map { $0.adapterShare * 100 })
                Spacer(minLength: 6)
                legend(color: Palette.amber, title: L("电池"),
                       watts: reading?.batteryToLoadW,
                       percent: reading.map { $0.batteryShare * 100 })
            }

            GeometryReader { geo in
                let share = reading?.adapterShare ?? 1
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.amber.opacity(0.25))
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.mint, Palette.mint.opacity(0.65)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * share))
                }
            }
            .frame(height: 6)
        }
    }

    private func legend(color: Color, title: String, watts: Double?, percent: Double?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text(PowerFormat.wattsWithUnit(watts))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
            if let percent {
                Text("(\(Int(percent.rounded()))%)")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - 时间窗口选择（自定义分段控件，避免依赖 @State/@Binding）

public struct WindowOption: Identifiable {
    public let id: Double
    public let label: String

    public init(_ label: String, _ seconds: Double) {
        self.label = label
        self.id = seconds
    }
}

public struct WindowPicker: View {
    let options: [WindowOption]
    let selected: Double
    let onSelect: (Double) -> Void

    public init(options: [WindowOption], selected: Double, onSelect: @escaping (Double) -> Void) {
        self.options = options
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 1) {
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    Text(option.label)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected == option.id ? Palette.mint.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(selected == option.id ? Palette.mint : Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }
}

// MARK: - 图例

public struct ChartLegend: View {
    let items: [(String, Color)]

    public init(items: [(String, Color)]) {
        self.items = items
    }

    public var body: some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.1)
                        .frame(width: 8, height: 8)
                    Text(item.0)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}


// MARK: - 温度

public struct TempChip: View {
    let label: String
    let icon: String
    let celsius: Double?
    let tint: Color

    public init(label: String, icon: String, celsius: Double?, tint: Color) {
        self.label = label
        self.icon = icon
        self.celsius = celsius
        self.tint = tint
    }

    /// 温度越高颜色越警示
    private var accent: Color {
        guard let celsius else { return .white.opacity(0.35) }
        if celsius >= 80 { return Color(red: 0.96, green: 0.45, blue: 0.38) }
        if celsius >= 65 { return Palette.amber }
        return tint
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(accent.opacity(0.9))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
            Text(celsius.map { String(format: "%.0f°", $0) } ?? "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(accent.opacity(0.10)))
    }
}

// MARK: - 磁盘 I/O

/// 磁盘读写徽章（速率用箭头区分读 / 写）
public struct DiskChip: View {
    public enum Kind {
        case read, write, capacity
    }

    let kind: Kind
    let label: String
    let value: String
    let detail: String?

    public init(kind: Kind, label: String, value: String, detail: String? = nil) {
        self.kind = kind
        self.label = label
        self.value = value
        self.detail = detail
    }

    private var icon: String {
        switch kind {
        case .read: return "arrow.down.circle.fill"
        case .write: return "arrow.up.circle.fill"
        case .capacity: return "internaldrive"
        }
    }

    private var tint: Color {
        switch kind {
        case .read: return Palette.mint
        case .write: return Palette.amber
        case .capacity: return Palette.blue
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(tint.opacity(0.9))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
            if let detail {
                Text(detail)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.10)))
    }
}

// MARK: - 内存 / 网络

/// 内存 / 网络徽章
public struct StatChip: View {
    public enum Kind {
        case memory, down, up, link, wifi, ethernet
    }

    let kind: Kind
    let label: String
    let value: String
    let detail: String?

    public init(kind: Kind, label: String = "", value: String, detail: String? = nil) {
        self.kind = kind
        self.label = label
        self.value = value
        self.detail = detail
    }

    private var icon: String {
        switch kind {
        case .memory: return "memorychip"
        case .down: return "arrow.down"
        case .up: return "arrow.up"
        case .link: return "bolt.horizontal.circle"
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        }
    }

    private var tint: Color {
        switch kind {
        case .memory: return Palette.purple
        case .down: return Palette.mint
        case .up: return Palette.amber
        case .link: return Palette.blue
        case .wifi: return Palette.blue
        case .ethernet: return Palette.mint
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint.opacity(0.9))
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
            if let detail {
                Text(detail)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.10)))
    }
}

/// 面板里的内存 / 网络条：内存 + 每个已连接接口各一个徽章，下面一行合计
public struct SystemStrip: View {
    public enum Style {
        case compact, detailed
    }

    let reading: PowerReading?
    let style: Style

    public init(reading: PowerReading?, style: Style = .compact) {
        self.reading = reading
        self.style = style
    }

    private var interfaces: [NetworkInterface] {
        reading?.networkInterfaces ?? []
    }

    public var body: some View {
        if let r = reading, r.memoryUsedShare != nil || !interfaces.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if r.memoryUsedShare != nil {
                        StatChip(kind: .memory,
                                 label: L("内存"),
                                 value: r.memoryUsedPercentText,
                                 detail: style == .detailed ? r.memoryText : nil)
                    }
                    // 每种连接方式一个徽章：以太网 / Wi-Fi 各自显示链路速率
                    ForEach(interfaces.prefix(4)) { iface in
                        StatChip(kind: iface.isWiFi ? .wifi : .ethernet,
                                 label: iface.name,
                                 value: iface.linkText)
                    }
                    Spacer(minLength: 0)
                }
                if !interfaces.isEmpty {
                    HStack(spacing: 5) {
                        Text("↓ " + r.netInText + "  ↑ " + r.netOutText)
                            .foregroundStyle(.white.opacity(0.55))
                        Text("· " + L("开机以来") + " ↓ " + r.netInTotalText + " ↑ " + r.netOutTotalText)
                            .foregroundStyle(.white.opacity(0.35))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 9))
                    .lineLimit(1)
                }
            }
        }
    }
}

/// 磁盘条：读 / 写速率 + 可用空间，以及 SSD SMART 的累计读写与健康度。
/// - compact：面板用，SSD 一行小字
/// - detailed：主窗口用，SSD 用独立徽章展示
public struct DiskStrip: View {
    public enum Style {
        case compact, detailed
    }

    let reading: PowerReading?
    let style: Style

    public init(reading: PowerReading?, style: Style = .compact) {
        self.reading = reading
        self.style = style
    }

    public var body: some View {
        if let r = reading, r.diskFreeBytes != nil || r.hasDiskActivity || r.hasSSDSmart {
            VStack(alignment: .leading, spacing: 4) {
                if r.diskFreeBytes != nil || r.hasDiskActivity {
                    HStack(spacing: 6) {
                        DiskChip(kind: .read, label: L("读"), value: r.diskReadText)
                        DiskChip(kind: .write, label: L("写"), value: r.diskWriteText)
                        if let used = r.diskUsedShare {
                            DiskChip(kind: .capacity,
                                     label: L("可用"),
                                     value: r.diskFreeText,
                                     detail: L("已用") + " " + String(format: "%.0f%%", used * 100))
                        }
                        Spacer(minLength: 0)
                    }
                }
                if r.hasSSDSmart {
                    switch style {
                    case .compact: ssdLine(r)
                    case .detailed: ssdChips(r)
                    }
                }
            }
        }
    }

    /// SSD SMART 徽章行（主窗口）
    @ViewBuilder
    private func ssdChips(_ r: PowerReading) -> some View {
        HStack(spacing: 6) {
            DiskChip(kind: .write, label: L("累计写入"), value: r.ssdWriteTotalText)
            DiskChip(kind: .read, label: L("累计读取"), value: r.ssdReadTotalText)
            DiskChip(kind: .capacity, label: L("健康度"), value: r.ssdHealthText)
            Spacer(minLength: 0)
        }
    }

    /// SSD SMART：累计写入 / 读取 + 健康度
    @ViewBuilder
    private func ssdLine(_ r: PowerReading) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 9))
                .foregroundStyle(Palette.blue.opacity(0.9))
            Text("SSD")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(L("累计写入") + " " + r.ssdWriteTotalText)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.6))
            Text("·").foregroundStyle(.white.opacity(0.25))
            Text(L("累计读取") + " " + r.ssdReadTotalText)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.6))
            Text("·").foregroundStyle(.white.opacity(0.25))
            Text(L("健康度") + " " + r.ssdHealthText)
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(healthTint(r))
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func healthTint(_ r: PowerReading) -> Color {
        guard let health = r.ssdHealthPercent else { return .white.opacity(0.5) }
        if health >= 80 { return Palette.mint }
        if health >= 60 { return Palette.amber }
        return Color(red: 0.96, green: 0.45, blue: 0.38)
    }
}

/// 面板里的紧凑温度条：只显示读得到的组件
public struct TempStrip: View {
    let reading: PowerReading?

    public init(reading: PowerReading?) {
        self.reading = reading
    }

    private var items: [(String, String, Double?, Color)] {
        guard let r = reading else { return [] }
        let all: [(String, String, Double?, Color)] = [
            ("CPU", "cpu", r.cpuTempC, Palette.blue),
            ("GPU", "display", r.gpuTempC, Palette.purple),
            ("SSD", "internaldrive", r.ssdTempC, Palette.mint),
            ("BAT", "battery.100percent", r.batteryTempC, Palette.amber),
        ]
        return all.filter { $0.2 != nil }
    }

    public var body: some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items, id: \.0) { item in
                    TempChip(label: item.0, icon: item.1, celsius: item.2, tint: item.3)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
