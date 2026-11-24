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

    /// 电池电压 / 电流（V / A；电流为负表示放电）
    public let batteryVoltageV: Double?
    public let batteryCurrentA: Double?

    /// 芯片分项功率（W，来自 IOReport Energy Model；读不到为 nil）
    public let cpuPowerW: Double?
    public let gpuPowerW: Double?
    public let anePowerW: Double?
    public let dramPowerW: Double?

    /// 组件温度（℃，读不到为 nil）
    public let cpuTempC: Double?
    public let gpuTempC: Double?
    public let ssdTempC: Double?
    public let batteryTempC: Double?
    public let platformTempC: Double?

    /// 风扇实际转速（RPM，多风扇取最大值）
    public let fanRPM: Double?
    /// 识别到的风扇数量
    public let fanCount: Int?
    /// 风扇转速范围（RPM）与目标转速
    public let fanMinRPM: Double?
    public let fanMaxRPM: Double?
    public let fanTargetRPM: Double?

    // SSD SMART（NVMe）：寿命、累计读写量、健康度
    public let ssdModel: String?
    public let ssdPercentUsed: Double?        // 寿命已用百分比
    public let ssdAvailableSpare: Double?     // 可用备用块百分比
    public let ssdSpareThreshold: Double?
    public let ssdReadBytesTotal: Double?     // 出厂以来累计读取
    public let ssdWriteBytesTotal: Double?    // 出厂以来累计写入
    public let ssdPowerOnHours: Double?
    public let ssdPowerCycles: Int?
    public let ssdUnsafeShutdowns: Int?
    public let ssdNvmeTempC: Double?

    // 磁盘 I/O（IOBlockStorageDriver 累计字节数的每秒增量）与容量
    public let diskCount: Int?
    public let diskReadBytesPerSec: Double?
    public let diskWriteBytesPerSec: Double?
    public let diskReadBytesTotal: Double?    // 开机以来累计
    public let diskWriteBytesTotal: Double?
    public let diskFreeBytes: Double?         // 启动卷可用空间
    public let diskTotalBytes: Double?

    // 电池容量 / 健康度 / 循环次数（AppleSmartBattery）
    public let batteryDesignCapacityMAh: Double?      // DesignCapacity
    public let batteryFullChargeCapacityMAh: Double?  // AppleRawMaxCapacity
    public let batteryCycleCount: Int?                // CycleCount
    public let batteryDesignCycleCount: Int?          // DesignCycleCount9C
    public let batteryHealthLabel: String?            // IOPS "Good" / "Fair" / "Poor"
    public let batteryHealthCondition: String?        // IOPS "Normal" / "Service Battery"

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

    /// 风扇是否已停转（M3/M4 空闲时热管理会完全关闭风扇，属正常现象）
    public var fanStopped: Bool {
        guard let fanRPM else { return false }
        return fanRPM < 1 && (fanMinRPM ?? 0) > 0
    }

    /// SSD SMART 是否有数据
    public var hasSSDSmart: Bool { ssdPercentUsed != nil || ssdReadBytesTotal != nil }

    /// SSD 健康度 = 100% - 寿命已用
    public var ssdHealthPercent: Double? {
        guard let used = ssdPercentUsed else { return nil }
        return max(0, min(100, 100 - used))
    }

    public var ssdHealthText: String {
        guard let health = ssdHealthPercent else { return "—" }
        return String(format: "%.0f%%", health)
    }

    /// 出厂以来累计读取 / 写入
    public var ssdReadTotalText: String { ByteFormat.size(ssdReadBytesTotal) }
    public var ssdWriteTotalText: String { ByteFormat.size(ssdWriteBytesTotal) }

    /// 可用备用块文案
    public var ssdSpareText: String {
        guard let spare = ssdAvailableSpare else { return "—" }
        return String(format: "%.0f%%", spare)
    }

    /// 通电小时数（数字，单位由界面补）
    public var ssdPowerOnHoursText: String {
        guard let hours = ssdPowerOnHours, hours >= 0 else { return "—" }
        return String(format: "%.0f", hours)
    }

    /// 磁盘是否有读数
    public var hasDiskActivity: Bool { diskReadBytesPerSec != nil || diskWriteBytesPerSec != nil }

    /// 读 / 写速率文案
    public var diskReadText: String { ByteFormat.rate(diskReadBytesPerSec) }
    public var diskWriteText: String { ByteFormat.rate(diskWriteBytesPerSec) }

    /// 本次开机以来的累计读写
    public var diskReadTotalText: String { ByteFormat.size(diskReadBytesTotal) }
    public var diskWriteTotalText: String { ByteFormat.size(diskWriteBytesTotal) }

    /// 启动卷可用 / 总容量文案
    public var diskFreeText: String { ByteFormat.size(diskFreeBytes) }
    public var diskCapacityText: String {
        guard let total = diskTotalBytes, total > 0 else { return "—" }
        let free = diskFreeText
        return free + " / " + ByteFormat.size(total)
    }

    /// 磁盘已用比例 0...1
    public var diskUsedShare: Double? {
        guard let total = diskTotalBytes, total > 0, let free = diskFreeBytes else { return nil }
        return max(0, min(1, 1 - free / total))
    }

    /// 电池健康度（满充容量 / 设计容量），0–130%，读不到为 nil
    public var batteryHealthPercent: Double? {
        guard hasBattery,
              let design = batteryDesignCapacityMAh, design > 100,
              let full = batteryFullChargeCapacityMAh, full > 100 else { return nil }
        let percent = full / design * 100.0
        guard percent.isFinite, percent > 1, percent < 130 else { return nil }
        return percent
    }

    /// 健康度文案，例如「94%」
    public var batteryHealthText: String {
        guard let percent = batteryHealthPercent else { return "—" }
        return String(format: "%.0f%%", percent)
    }

    /// 满充容量 / 设计容量文案，例如「5640 / 6075 mAh」
    public var batteryCapacityText: String {
        guard let full = batteryFullChargeCapacityMAh,
              let design = batteryDesignCapacityMAh else { return "—" }
        return String(format: "%.0f / %.0f mAh", full, design)
    }

    /// 循环次数文案，例如「213 次」
    public var batteryCycleText: String {
        guard let cycles = batteryCycleCount else { return "—" }
        return "\(cycles) 次"
    }

    public var hasBatteryHealth: Bool { batteryHealthPercent != nil }

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
        cpuPowerW: Double? = nil,
        gpuPowerW: Double? = nil,
        anePowerW: Double? = nil,
        dramPowerW: Double? = nil,
        inputVoltageV: Double? = nil,
        inputCurrentA: Double? = nil,
        batteryVoltageV: Double? = nil,
        batteryCurrentA: Double? = nil,
        cpuTempC: Double? = nil,
        gpuTempC: Double? = nil,
        ssdTempC: Double? = nil,
        batteryTempC: Double? = nil,
        platformTempC: Double? = nil,
        fanRPM: Double? = nil,
        fanCount: Int? = nil,
        fanMinRPM: Double? = nil,
        fanMaxRPM: Double? = nil,
        fanTargetRPM: Double? = nil,
        ssdModel: String? = nil,
        ssdPercentUsed: Double? = nil,
        ssdAvailableSpare: Double? = nil,
        ssdSpareThreshold: Double? = nil,
        ssdReadBytesTotal: Double? = nil,
        ssdWriteBytesTotal: Double? = nil,
        ssdPowerOnHours: Double? = nil,
        ssdPowerCycles: Int? = nil,
        ssdUnsafeShutdowns: Int? = nil,
        ssdNvmeTempC: Double? = nil,
        diskCount: Int? = nil,
        diskReadBytesPerSec: Double? = nil,
        diskWriteBytesPerSec: Double? = nil,
        diskReadBytesTotal: Double? = nil,
        diskWriteBytesTotal: Double? = nil,
        diskFreeBytes: Double? = nil,
        diskTotalBytes: Double? = nil,
        batteryDesignCapacityMAh: Double? = nil,
        batteryFullChargeCapacityMAh: Double? = nil,
        batteryCycleCount: Int? = nil,
        batteryDesignCycleCount: Int? = nil,
        batteryHealthLabel: String? = nil,
        batteryHealthCondition: String? = nil,
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
        self.cpuPowerW = cpuPowerW
        self.gpuPowerW = gpuPowerW
        self.anePowerW = anePowerW
        self.dramPowerW = dramPowerW
        self.inputVoltageV = inputVoltageV
        self.inputCurrentA = inputCurrentA
        self.batteryVoltageV = batteryVoltageV
        self.batteryCurrentA = batteryCurrentA
        self.cpuTempC = cpuTempC
        self.gpuTempC = gpuTempC
        self.ssdTempC = ssdTempC
        self.batteryTempC = batteryTempC
        self.platformTempC = platformTempC
        self.fanRPM = fanRPM
        self.fanCount = fanCount
        self.fanTargetRPM = fanTargetRPM
        self.fanMinRPM = fanMinRPM
        self.fanMaxRPM = fanMaxRPM
        self.ssdModel = ssdModel
        self.ssdPercentUsed = ssdPercentUsed
        self.ssdAvailableSpare = ssdAvailableSpare
        self.ssdSpareThreshold = ssdSpareThreshold
        self.ssdReadBytesTotal = ssdReadBytesTotal
        self.ssdWriteBytesTotal = ssdWriteBytesTotal
        self.ssdPowerOnHours = ssdPowerOnHours
        self.ssdPowerCycles = ssdPowerCycles
        self.ssdUnsafeShutdowns = ssdUnsafeShutdowns
        self.ssdNvmeTempC = ssdNvmeTempC
        self.diskCount = diskCount
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.diskReadBytesTotal = diskReadBytesTotal
        self.diskWriteBytesTotal = diskWriteBytesTotal
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
        self.batteryDesignCapacityMAh = batteryDesignCapacityMAh
        self.batteryFullChargeCapacityMAh = batteryFullChargeCapacityMAh
        self.batteryCycleCount = batteryCycleCount
        self.batteryDesignCycleCount = batteryDesignCycleCount
        self.batteryHealthLabel = batteryHealthLabel
        self.batteryHealthCondition = batteryHealthCondition
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

/// 磁盘 / 容量的字节格式化（十进制单位，与活动监视器一致）
public enum ByteFormat {
    public static func rate(_ bytesPerSec: Double?) -> String {
        guard let value = bytesPerSec, value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000_000 { return String(format: "%.2f GB/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
    }

    public static func size(_ bytes: Double?) -> String {
        guard let value = bytes, value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000_000_000 { return String(format: "%.2f TB", value / 1_000_000_000_000) }
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.0f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB", value / 1_000) }
        return String(format: "%.0f B", value)
    }
}

/// 菜单栏数值的取值口径。
///
/// 默认显示「电源输入」（适配器 DC 输入功率，也就是机器从电源实际拿到的功率）；
/// 台式机没有电池时适配器输入等于整机负载，两者一致。
public enum MenuBarMetric: String, CaseIterable {
    /// 适配器 DC 输入功率（未接电源时回退到整机功耗）
    case adapterInput
    /// 墙插估算功率（DC 输入 + 适配器损耗；台式机含电源损耗）
    case wallPower
    /// 整机功耗（PSTR / 系统负载）
    case systemPower
    /// 电池净功率（正 = 充电，负 = 放电）
    case batteryPower

    public static let defaultsKey = "wattmeter.menubar.metric"

    public var title: String {
        switch self {
        case .adapterInput: return "电源输入"
        case .wallPower:    return "墙插估算"
        case .systemPower:  return "整机功耗"
        case .batteryPower: return "电池功率"
        }
    }

    /// 当前读数下这一口径的功率；返回 nil 表示没有可用值
    public func value(for reading: PowerReading) -> Double? {
        switch self {
        case .adapterInput:
            if let input = reading.adapterInputW, input.isFinite, input > 0.05 {
                return input
            }
            // 电池供电时没有输入功率：回退到整机功耗，避免菜单栏没有数字
            return reading.systemPowerW ?? reading.adapterToLoadW + reading.batteryToLoadW
        case .wallPower:
            if let wall = reading.wallPowerW, wall.isFinite, wall > 0.05 {
                return wall
            }
            if let input = reading.adapterInputW, input.isFinite, input > 0.05 {
                return input
            }
            return reading.systemPowerW ?? reading.adapterToLoadW + reading.batteryToLoadW
        case .systemPower:
            return reading.totalW
        case .batteryPower:
            guard let battery = reading.batteryPowerW, battery.isFinite else { return nil }
            return battery
        }
    }

    /// 菜单栏文字（不含前导空格）；无法计算时返回空字符串，由调用方决定回退
    public func text(for reading: PowerReading) -> String {
        guard let value = value(for: reading), value.isFinite else { return "" }
        switch self {
        case .batteryPower:
            // 充电 / 放电用符号区分；接近 0 时不带符号
            guard abs(value) >= 0.05 else { return "0.0W" }
            let sign = value >= 0 ? "+" : "−"
            return sign + PowerFormat.watts(abs(value)) + "W"
        default:
            return PowerFormat.watts(value) + "W"
        }
    }
}
