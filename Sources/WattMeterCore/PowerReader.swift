import Foundation
import CSystemPower

/// 把 C 层采集到的原始数据换算成 `PowerReading`。
///
/// 功率来源优先级：
///   1. AppleSMC 的 PSTR / PDTR / PD0R（约 0.4~1 秒刷新，实时）
///   2. IORegistry PowerTelemetryData（约 20 秒才刷新，作为兜底）
/// 电池功率优先用 `Voltage × Amperage`（实时），符号由充电/供电状态归一化。
public final class PowerReader {
    private let handle: OpaquePointer?

    /// 磁盘计数器上一次的采样值（用来把累计字节数变成 MB/s）
    private var lastDiskSample: (read: Double, write: Double, at: Date)?
    /// 启动卷容量缓存（statfs 不必每秒都做）
    private var cachedVolume: (free: Double?, total: Double?, at: Date)?

    public init() {
        handle = sp_reader_create()
    }

    deinit {
        if let handle { sp_reader_destroy(handle) }
    }

    public var isSMCReady: Bool {
        guard let handle else { return false }
        var probe = SPReading()
        return sp_reader_read(handle, &probe) == 0 && probe.smcAvailable != 0
    }

    /// 采集一次。返回 nil 表示读不到任何可用数据。
    public func read() -> PowerReading? {
        guard let handle else { return nil }
        var raw = SPReading()
        guard sp_reader_read(handle, &raw) == 0 else { return nil }

        let hasBattery = raw.batteryInstalled != 0
        let onAC = raw.externalConnected != 0
        let telemetry = raw.telemetryAvailable != 0

        // ── 整机功率 ────────────────────────────────────────────────
        var systemW: Double?
        if raw.smcHasSystemPower != 0, raw.smcSystemPower_W > 0.05 {
            systemW = raw.smcSystemPower_W
        } else if telemetry, raw.systemLoad_mW > 0 {
            systemW = raw.systemLoad_mW / 1000.0
        }

        // ── 适配器输入 ──────────────────────────────────────────────
        var adapterInW: Double?
        if raw.smcHasAdapterPower != 0, raw.smcAdapterPower_W > 0.05 {
            adapterInW = raw.smcAdapterPower_W
        } else if raw.smcHasDesktopInputPower != 0, raw.smcDesktopInputPower_W > 0.05 {
            adapterInW = raw.smcDesktopInputPower_W
        } else if telemetry, raw.systemPowerIn_mW > 0 {
            adapterInW = raw.systemPowerIn_mW / 1000.0
        }

        let dataSource: PowerDataSource =
            (raw.smcHasSystemPower != 0 || raw.smcHasAdapterPower != 0) ? .smc : .telemetry

        // 台式机没有电池：适配器输入就等于整机负载。
        // （台式机 PDTR 可能包含电源自身损耗、且与 PSTR 有采样差，直接展示会自相矛盾）
        let measuredInputW = adapterInW
        if !hasBattery, let systemW, systemW > 0 {
            adapterInW = systemW
        }

        // ── 电池功率 ────────────────────────────────────────────────
        var batteryW: Double?
        if hasBattery {
            // 1) 电压 × 电流（实时）。Amperage 符号：Apple 约定负值=放电。
            let volts = raw.batteryVoltage_mV
            let amps = raw.batteryAmperage_mA
            if volts > 1000, amps.isFinite, amps != 0 {
                let measured = volts * amps / 1_000_000.0
                if abs(measured) < 300 {
                    batteryW = normalizeBatteryPower(measured, charging: raw.isCharging != 0,
                                                     onAC: onAC, charged: raw.isCharged != 0)
                }
            }
            // 2) 兜底：Telemetry 的 BatteryPower（幅值可信，符号未知）
            if batteryW == nil, telemetry, raw.batteryPower_mW != 0 {
                let magnitude = abs(raw.batteryPower_mW) / 1000.0
                if magnitude < 300 {
                    batteryW = normalizeBatteryPower(magnitude,
                                                     charging: raw.isCharging != 0,
                                                     onAC: onAC, charged: raw.isCharged != 0)
                }
            }
        }

        // ── 功率分流 ────────────────────────────────────────────────
        let load = systemW ?? 0
        let split = Self.split(input: adapterInW, load: load,
                               hasBattery: hasBattery, onAC: onAC)

        // 未接电源时，适配器输入不参与展示（PDTR 可能残留）
        if !onAC, hasBattery {
            adapterInW = nil
        }

        // 整机功率读不到时，用电池放电功率回推（电池供电场景）
        if systemW == nil, !onAC, let batteryW, batteryW < -0.05 {
            systemW = -batteryW
        }

        // 混合供电：电池在放电，净功率必须是负值（修正个别机型的符号/标志不一致）
        if var battery = batteryW, battery > 0.05,
           split.batteryToLoad > 0.5, raw.isCharging == 0 {
            battery = -abs(battery)
            batteryW = battery
        }
        let adapterToLoad = split.adapterToLoad
        let batteryToLoad = split.batteryToLoad
        let chargeW = split.charge

        // ── 墙插估算 ────────────────────────────────────────────────
        var wallW: Double?
        var lossW: Double?
        if !hasBattery {
            // 台式机：取 PDTR（含电源损耗）与整机功率的较大者，再加系统给的损耗估计
            let measured = max(measuredInputW ?? 0, systemW ?? 0)
            if measured > 0.2 {
                lossW = telemetry && raw.adapterEfficiencyLoss_mW > 0
                    ? raw.adapterEfficiencyLoss_mW / 1000.0 : measured * 0.1
                wallW = measured + (lossW ?? 0)
            }
        } else if let input = adapterInW, input > 0.2 {
            if telemetry, raw.adapterEfficiencyLoss_mW > 0,
               raw.adapterEfficiencyLoss_mW / 1000.0 < input * 0.5 {
                lossW = raw.adapterEfficiencyLoss_mW / 1000.0
                wallW = input + lossW!
            } else {
                // 没有损耗遥测时，按 90% 电源效率估算
                lossW = input * 0.1
                wallW = input / 0.9
            }
        }

        // ── 电池百分比 / 剩余时间 ───────────────────────────────────
        var soc: Double?
        if raw.socPercent >= 0, raw.socPercent <= 100 {
            soc = raw.socPercent
        }
        var remaining: Double?
        if raw.timeRemainingMinutes > 0 {
            remaining = raw.timeRemainingMinutes
        }

        // 输入电压 / 电流：优先 SMC 的 VD0R / ID0R（实时），否则用遥测（约 20 秒）
        var inputV: Double?
        var inputA: Double?
        if raw.smcHasInputRails != 0, raw.smcInputVoltage_V > 0.1 {
            inputV = raw.smcInputVoltage_V
            inputA = raw.smcInputCurrent_A >= 0 ? raw.smcInputCurrent_A : nil
        } else if telemetry, raw.systemVoltageIn_mV > 500 {
            inputV = raw.systemVoltageIn_mV / 1000.0
            inputA = raw.systemCurrentIn_mA > 0 ? raw.systemCurrentIn_mA / 1000.0 : nil
        }

        // 分项（笔记本机型可用）
        let displayW: Double? = raw.displayAvailable != 0 && raw.displayPower_W >= 0
            ? raw.displayPower_W : nil
        var portW: Double? = raw.portTelemetryAvailable != 0 ? raw.portPower_W : nil

        // 充电时，充电口的输入也会出现在 D1..D4 供电轨里。
        // 用「与适配器输入功率接近」来判掉那一条，避免把输入当成对外供电。
        if let currentPort = portW, currentPort > 0.5,
           raw.isCharging != 0, let input = measuredInputW, input > 0.5 {
            let rails = raw.portRailPowers
            if let index = rails.firstIndex(where: { abs($0 - input) <= max(2.0, input * 0.15) }) {
                let filtered = rails.enumerated()
                    .filter { $0.offset != index }
                    .reduce(0.0) { $0 + $1.element }
                portW = filtered > 0.05 ? filtered : 0
            }
        }
        func temp(_ value: Double) -> Double? {
            value.isFinite && value > -20 && value < 150 ? value : nil
        }
        func chip(_ watts: Double) -> Double? {
            watts.isFinite && watts >= 0.01 && watts < 600 ? watts : nil
        }
        let batteryVoltageV: Double? = raw.batteryVoltage_mV > 1000 ? raw.batteryVoltage_mV / 1000.0 : nil
        let batteryCurrentA: Double? = raw.batteryInstalled != 0 ? raw.batteryAmperage_mA / 1000.0 : nil
        let fanW: Double? = raw.fanAvailable != 0 ? raw.fanRPM : nil
        let fanCount: Int? = raw.fanAvailable != 0 ? Int(raw.fanCount) : nil
        let fanTarget: Double? = raw.fanAvailable != 0 && raw.fanTargetRPM > 0 ? raw.fanTargetRPM : nil
        let fanMin: Double? = raw.fanAvailable != 0 && raw.fanMinRPM > 0 ? raw.fanMinRPM : nil
        let fanMax: Double? = raw.fanAvailable != 0 && raw.fanMaxRPM > 0 ? raw.fanMaxRPM : nil

        // ── 磁盘 I/O：累计字节数 → 每秒速率 ──────────────────────────
        let now = Date()
        var diskReadRate: Double?
        var diskWriteRate: Double?
        if raw.diskAvailable != 0 {
            if let last = lastDiskSample {
                let elapsed = now.timeIntervalSince(last.at)
                if elapsed > 0.2, elapsed < 10 {
                    // 计数器可能因磁盘插拔归零，负增量按 0 处理
                    diskReadRate = max(0, raw.diskReadBytes - last.read) / elapsed
                    diskWriteRate = max(0, raw.diskWriteBytes - last.write) / elapsed
                }
            }
            lastDiskSample = (raw.diskReadBytes, raw.diskWriteBytes, now)
        } else {
            lastDiskSample = nil
        }
        let diskReadTotal: Double? = raw.diskAvailable != 0 ? raw.diskReadBytes : nil
        let diskWriteTotal: Double? = raw.diskAvailable != 0 ? raw.diskWriteBytes : nil

        // 启动卷容量（5 秒缓存）
        var volumeFree: Double?
        var volumeTotal: Double?
        if let cached = cachedVolume, now.timeIntervalSince(cached.at) < 5 {
            volumeFree = cached.free
            volumeTotal = cached.total
        } else {
            let values = Self.volumeCapacity()
            volumeFree = values.free
            volumeTotal = values.total
            cachedVolume = (values.free, values.total, now)
        }

        return PowerReading(
            systemPowerW: systemW,
            adapterInputW: adapterInW,
            batteryPowerW: batteryW,
            adapterRatedW: raw.adapterKnown != 0 && raw.adapterRatedWatts > 0 ? raw.adapterRatedWatts : nil,
            adapterName: raw.adapterNameString.isEmpty ? nil : raw.adapterNameString,
            wallPowerW: wallW,
            adapterLossW: lossW,
            adapterToLoadW: adapterToLoad,
            batteryToLoadW: batteryToLoad,
            chargeW: chargeW,
            hasBattery: hasBattery,
            onAC: onAC,
            isCharging: raw.isCharging != 0,
            isCharged: raw.isCharged != 0,
            batteryPercent: soc,
            timeRemainingMinutes: remaining,
            displayPowerW: displayW,
            portPowerW: portW,
            cpuPowerW: chipPower(raw, available: raw.cpuPowerAvailable, value: raw.cpuPowerW),
            gpuPowerW: chipPower(raw, available: raw.gpuPowerAvailable, value: raw.gpuPowerW),
            anePowerW: chipPower(raw, available: raw.anePowerAvailable, value: raw.anePowerW),
            dramPowerW: chipPower(raw, available: raw.dramPowerAvailable, value: raw.dramPowerW),
            inputVoltageV: inputV,
            inputCurrentA: inputA,
            batteryVoltageV: batteryVoltageV,
            batteryCurrentA: batteryCurrentA,
            cpuTempC: temp(raw.cpuTempC),
            gpuTempC: temp(raw.gpuTempC),
            ssdTempC: temp(raw.ssdTempC),
            batteryTempC: temp(raw.batteryTempC),
            platformTempC: temp(raw.platformTempC),
            fanRPM: fanW,
            fanCount: fanCount,
            fanMinRPM: fanMin,
            fanMaxRPM: fanMax,
            fanTargetRPM: fanTarget,
            ssdModel: raw.ssdSmartAvailable != 0 && !raw.ssdModelString.isEmpty ? raw.ssdModelString : nil,
            ssdPercentUsed: raw.ssdSmartAvailable != 0 ? raw.ssdPercentUsed : nil,
            ssdAvailableSpare: raw.ssdSmartAvailable != 0 ? raw.ssdAvailableSpare : nil,
            ssdSpareThreshold: raw.ssdSmartAvailable != 0 ? raw.ssdSpareThreshold : nil,
            ssdReadBytesTotal: raw.ssdSmartAvailable != 0 && raw.ssdReadBytes > 0 ? raw.ssdReadBytes : nil,
            ssdWriteBytesTotal: raw.ssdSmartAvailable != 0 && raw.ssdWriteBytes > 0 ? raw.ssdWriteBytes : nil,
            ssdPowerOnHours: raw.ssdSmartAvailable != 0 && raw.ssdPowerOnHours > 0 ? raw.ssdPowerOnHours : nil,
            ssdPowerCycles: raw.ssdSmartAvailable != 0 && raw.ssdPowerCycles > 0
                ? Int(raw.ssdPowerCycles) : nil,
            ssdUnsafeShutdowns: raw.ssdSmartAvailable != 0 ? Int(raw.ssdUnsafeShutdowns) : nil,
            ssdNvmeTempC: raw.ssdSmartAvailable != 0 && raw.ssdNvmeTempC > -20 && raw.ssdNvmeTempC < 120
                ? raw.ssdNvmeTempC : nil,
            diskCount: raw.diskAvailable != 0 ? Int(raw.diskCount) : nil,
            diskReadBytesPerSec: diskReadRate,
            diskWriteBytesPerSec: diskWriteRate,
            diskReadBytesTotal: diskReadTotal,
            diskWriteBytesTotal: diskWriteTotal,
            diskFreeBytes: volumeFree,
            diskTotalBytes: volumeTotal,
            // 台式机的 IORegistry 里也会有一个空的 AppleSmartBattery 节点
            //（容量 / 循环次数都是 0），只有真正装了电池才展示这些字段。
            batteryDesignCapacityMAh: hasBattery && raw.batteryCapacityAvailable != 0
                && raw.batteryDesignCapacity_mAh > 0 ? raw.batteryDesignCapacity_mAh : nil,
            batteryFullChargeCapacityMAh: hasBattery && raw.batteryCapacityAvailable != 0
                && raw.batteryFullChargeCapacity_mAh > 0 ? raw.batteryFullChargeCapacity_mAh : nil,
            batteryCycleCount: hasBattery && raw.batteryCycleCount >= 0 ? Int(raw.batteryCycleCount) : nil,
            batteryDesignCycleCount: hasBattery && raw.batteryDesignCycleCount > 0
                ? Int(raw.batteryDesignCycleCount) : nil,
            batteryHealthLabel: hasBattery && !raw.batteryHealthString.isEmpty ? raw.batteryHealthString : nil,
            batteryHealthCondition: hasBattery && !raw.batteryHealthConditionString.isEmpty
                ? raw.batteryHealthConditionString : nil,
            source: dataSource
        )
    }

    /// 启动卷可用 / 总容量（字节）
    private static func volumeCapacity() -> (free: Double?, total: Double?) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) else {
            return (nil, nil)
        }
        let total = values.volumeTotalCapacity.map(Double.init)
        let free = values.volumeAvailableCapacityForImportantUsage.map(Double.init)
        return (free, total)
    }

    /// 供电源分流结果。
    public struct PowerSplit: Sendable, Equatable {
        public let adapterToLoad: Double
        public let batteryToLoad: Double
        public let charge: Double
    }

    /// 把「输入功率 / 系统负载 / 电池状态」拆成三个去向：
    /// - `adapterToLoad`：电源供给负载的部分
    /// - `batteryToLoad`：电池补足负载的部分（混合供电时 > 0）
    /// - `charge`：电源给电池充电的部分
    ///
    /// 关键规则：
    /// 1. 弱充电器 + 高负载时 `load > input`，电池会参与供电（混合供电）；
    /// 2. 台式机没有电池，全部来自电源；
    /// 3. 有电池且接着电源时用 0.7 W 死区，避免采样相位差造成的抖动。
    public static func split(input: Double?, load: Double,
                             hasBattery: Bool, onAC: Bool) -> PowerSplit {
        var adapterToLoad = 0.0
        var batteryToLoad = 0.0
        var charge = 0.0

        if !onAC, hasBattery {
            // 拔掉电源的瞬间 PDTR 可能还有残留值，电池模式下必须忽略它
            batteryToLoad = load
        } else if let input, input > 0.05 {
            adapterToLoad = min(input, load)
            batteryToLoad = max(0, load - input)
            charge = max(0, input - load)
        } else if onAC || !hasBattery {
            adapterToLoad = load
        } else {
            batteryToLoad = load
        }

        // 电池模式但没有拆分数据时，把负载全部算作电池供电
        if !onAC, hasBattery, batteryToLoad == 0, adapterToLoad > 0 {
            batteryToLoad = adapterToLoad
            adapterToLoad = 0
        }

        // 台式机没有电池：全部负载来自电源
        if !hasBattery {
            adapterToLoad = load
            batteryToLoad = 0
            charge = 0
        }

        // 采样相位差死区
        if hasBattery, onAC, batteryToLoad < 0.7 {
            adapterToLoad = load
            batteryToLoad = 0
        }
        if hasBattery, onAC, charge < 0.7 {
            charge = 0
        }

        return PowerSplit(adapterToLoad: adapterToLoad,
                          batteryToLoad: batteryToLoad,
                          charge: charge)
    }

    /// 导出所有风扇相关 SMC 键（诊断用）
    public func dumpFanKeys() -> String {
        guard let handle else { return "" }
        var buffer = [CChar](repeating: 0, count: 16384)
        let written = sp_reader_dump_fan_keys(handle, &buffer, 16384)
        guard written > 0 else { return "" }
        return String(cString: buffer)
    }

    /// 导出 AppleSmartBattery 的容量 / 循环 / 健康键（诊断用）
    public func dumpBatteryKeys() -> String {
        var buffer = [CChar](repeating: 0, count: 16384)
        let written = sp_reader_dump_battery_keys(&buffer, 16384)
        guard written > 0 else { return "" }
        return String(cString: buffer)
    }

    /// 导出 IOReport 能耗通道（诊断用）
    public func dumpEnergyChannels() -> String {
        guard let handle else { return "" }
        var buffer = [CChar](repeating: 0, count: 32768)
        let written = sp_reader_dump_energy_channels(handle, &buffer, 32768)
        guard written > 0 else { return "" }
        return String(cString: buffer)
    }

    /// 读取任意 SMC flt 键（扩展/调试用），单位通常为 W。
    public func smcFloat(_ key: String) -> Double? {
        guard let handle else { return nil }
        var value: Double = 0
        guard sp_reader_read_smc_float(handle, key, &value) == 0 else { return nil }
        return value
    }

    /// 该 SMC 键是否存在且为 flt 类型。
    public func smcHasKey(_ key: String) -> Bool {
        guard let handle else { return false }
        return sp_reader_smc_key_exists(handle, key) != 0
    }

    /// 分项功率：通道存在且读数合理才返回，否则视为「没法获取」（界面会隐藏该分项）。
    private func chipPower(_ raw: SPReading, available: Int32, value: Double) -> Double? {
        guard available != 0, value.isFinite, value >= 0.01, value < 600 else { return nil }
        return value
    }

    /// 把电流符号的实测值，按“充电为正、放电为负”归一化。
    private func normalizeBatteryPower(_ measured: Double, charging: Bool,
                                       onAC: Bool, charged: Bool) -> Double {
        if charging { return abs(measured) }
        if !onAC { return -abs(measured) }
        // 接着电源但没在充电：只有电流为负才是「电池在补足负载」（混合供电）
        if measured < -0.05 { return -abs(measured) }
        return 0
    }
}

extension SPReading {
    /// C 结构里的 4 条 USB-C 供电轨
    var portRailPowers: [Double] {
        withUnsafeBytes(of: portRailPower_W) { buffer in
            let count = min(max(Int(portRailCount), 0), 4)
            let values = buffer.bindMemory(to: Double.self)
            return (0..<count).map { values[$0] }
        }
    }
}

private extension SPReading {
    /// 读取 C 结构里的定长字符串
    var adapterNameString: String {
        withUnsafeBytes(of: adapterName) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    var ssdModelString: String {
        withUnsafeBytes(of: ssdModel) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    var batteryHealthString: String {
        withUnsafeBytes(of: batteryHealth) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    var batteryHealthConditionString: String {
        withUnsafeBytes(of: batteryHealthCondition) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
