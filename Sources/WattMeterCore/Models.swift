import Foundation

/// 功率读数来源
public enum PowerDataSource: String, Sendable {
    case smc       // AppleSMC（PSTR/PDTR，实时）
    case telemetry // IORegistry PowerTelemetryData（约 20 秒刷新）
    case synthetic // 演示数据

    public var label: String {
        switch self {
        case .smc: return "SMC 实时"
        case .telemetry: return "系统遥测（约 20 秒刷新）"
        case .synthetic: return "演示数据"
        }
    }
}

/// 一次采样得到的功率快照。
///
/// 约定：
///   - 所有功率单位是 W（瓦）。
///   - `batteryPowerW` 有符号：正数 = 正在给电池充电，负数 = 电池在放电。
///   - `adapterToLoadW` / `batteryToLoadW` 是“供给负载”的拆分，满足
///     `adapterToLoadW + batteryToLoadW ≈ systemPowerW`。
public struct PowerReading: Identifiable, Sendable {
    public let timestamp: Date

    /// 整机功耗（SMC PSTR；没有 SMC 时用 Telemetry 的 SystemLoad）
    public let systemPowerW: Double?
    /// 适配器 DC 输入功率（SMC PDTR / PD0R；没有时用 Telemetry 的 SystemPowerIn）
    public let adapterInputW: Double?
    /// 电池净功率，正 = 充电，负 = 放电
    public let batteryPowerW: Double?
    /// 适配器额定功率（例如 67W）
    public let adapterRatedW: Double?
    public let adapterName: String?
    /// 估算的墙插功率（适配器输入 + 损耗）
    public let wallPowerW: Double?
    /// 适配器/充电电路损耗（来自 Telemetry，可能没有）
    public let adapterLossW: Double?

    /// 供给负载的功率拆分
    public let adapterToLoadW: Double
    public let batteryToLoadW: Double
    /// 给电池充电的功率（>0 表示正在充）
    public let chargeW: Double

    public let hasBattery: Bool
    public let onAC: Bool
    public let isCharging: Bool
    public let isCharged: Bool
    public let batteryPercent: Double?
    /// 剩余时间（分钟）；nil 或负数表示未知/不限
    public let timeRemainingMinutes: Double?

    /// 内置屏幕背光功率（PDBR / PBwo / PBLR，部分机型可读）
    public let displayPowerW: Double?
    /// 对外供电接口功率（PowerOutDetails 汇总，部分机型可读）
    public let portPowerW: Double?

    /// 适配器输入电压 / 电流（V / A，SMC VD0R × ID0R；缺失时用遥测兜底）
    public let inputVoltageV: Double?
    public let inputCurrentA: Double?

    /// 组件温度（℃，读不到为 nil）
    public let cpuTempC: Double?
    public let gpuTempC: Double?
    public let ssdTempC: Double?
    public let batteryTempC: Double?
    public let platformTempC: Double?

    /// 风扇实际转速（RPM，SMC F0Ac）
    public let fanRPM: Double?
    /// 风扇转速范围（RPM，SMC F0Mn / F0Mx）
    public let fanMinRPM: Double?
    public let fanMaxRPM: Double?

    public let source: PowerDataSource

    public var id: Double { timestamp.timeIntervalSince1970 }

    /// 展示用的整机功率（缺失时退化为拆分之和）
    public var totalW: Double { systemPowerW ?? (adapterToLoadW + batteryToLoadW) }

    /// 电源供给占比 0...1（台式机/满电接电时约等于 1）
    public var adapterShare: Double {
        let total = adapterToLoadW + batteryToLoadW
        guard total > 0.05 else { return onAC ? 1 : 0 }
        return adapterToLoadW / total
    }

    public var batteryShare: Double { max(0, min(1, 1 - adapterShare)) }

    /// 扣掉已知分项后的「系统」功率（CPU/内存/其他）
    public var systemComponentW: Double {
        max(0, totalW - (displayPowerW ?? 0) - (portPowerW ?? 0))
    }

    /// 输入电压 × 电流文案
    public var inputRailsText: String? {
        guard let inputVoltageV, inputVoltageV > 0 else { return nil }
        if let inputCurrentA {
            return String(format: "%.2f V × %.2f A", inputVoltageV, inputCurrentA)
        }
        return String(format: "%.2f V", inputVoltageV)
    }

    /// 最高组件温度（用于菜单栏 tooltip / 概览）
    public var hottestTempC: Double? {
        [cpuTempC, gpuTempC, ssdTempC, batteryTempC, platformTempC]
            .compactMap { $0 }
            .max()
    }

    /// 温度文案
    public static func temperatureText(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return String(format: "%.0f°C", celsius)
    }

    /// 风扇转速文案
    public var fanText: String {
        guard let fanRPM else { return "—" }
        return String(format: "%.0f", fanRPM)
    }

    /// 是否处于「电源 + 电池」混合供电（弱充电器无法单独满足负载，电池补足）
    public var isHybrid: Bool {
        hasBattery && onAC && batteryToLoadW > 0.5
    }

    /// 电池状态文案
    public var batteryStateText: String {
        guard hasBattery else { return "无内置电池" }
        if isHybrid { return "混合供电" }
        if isCharging { return "充电中" }
        if onAC {
            return isCharged ? "已充满" : "外接电源"
        }
        return "电池供电"
    }

    public var timeRemainingText: String {
        guard hasBattery, let minutes = timeRemainingMinutes else { return "—" }
        if minutes < 0 { return "计算中" }
        let m = Int(minutes.rounded())
        if m >= 60 { return "\(m / 60) 小时 \(m % 60) 分" }
        return "\(m) 分钟"
    }

    public init(
        timestamp: Date = Date(),
        systemPowerW: Double?,
        adapterInputW: Double?,
        batteryPowerW: Double?,
        adapterRatedW: Double?,
        adapterName: String?,
        wallPowerW: Double?,
        adapterLossW: Double?,
        adapterToLoadW: Double,
        batteryToLoadW: Double,
        chargeW: Double,
        hasBattery: Bool,
        onAC: Bool,
        isCharging: Bool,
        isCharged: Bool,
        batteryPercent: Double?,
        timeRemainingMinutes: Double?,
        displayPowerW: Double? = nil,
        portPowerW: Double? = nil,
        inputVoltageV: Double? = nil,
        inputCurrentA: Double? = nil,
        cpuTempC: Double? = nil,
        gpuTempC: Double? = nil,
        ssdTempC: Double? = nil,
        batteryTempC: Double? = nil,
        platformTempC: Double? = nil,
        fanRPM: Double? = nil,
        fanMinRPM: Double? = nil,
        fanMaxRPM: Double? = nil,
        source: PowerDataSource
    ) {
        self.timestamp = timestamp
        self.systemPowerW = systemPowerW
        self.adapterInputW = adapterInputW
        self.batteryPowerW = batteryPowerW
        self.adapterRatedW = adapterRatedW
        self.adapterName = adapterName
        self.wallPowerW = wallPowerW
        self.adapterLossW = adapterLossW
        self.adapterToLoadW = adapterToLoadW
        self.batteryToLoadW = batteryToLoadW
        self.chargeW = chargeW
        self.hasBattery = hasBattery
        self.onAC = onAC
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.batteryPercent = batteryPercent
        self.timeRemainingMinutes = timeRemainingMinutes
        self.displayPowerW = displayPowerW
        self.portPowerW = portPowerW
        self.inputVoltageV = inputVoltageV
        self.inputCurrentA = inputCurrentA
        self.cpuTempC = cpuTempC
        self.gpuTempC = gpuTempC
        self.ssdTempC = ssdTempC
        self.batteryTempC = batteryTempC
        self.platformTempC = platformTempC
        self.fanRPM = fanRPM
        self.fanMinRPM = fanMinRPM
        self.fanMaxRPM = fanMaxRPM
        self.source = source
    }
}

/// 小工具：统一功率格式化
public enum PowerFormat {
    public static func watts(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f", value)
    }

    public static func wattsWithUnit(_ value: Double?, digits: Int = 1) -> String {
        "\(watts(value, digits: digits)) W"
    }
}
