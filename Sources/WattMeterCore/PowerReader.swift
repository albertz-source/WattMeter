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
        var adapterToLoad = 0.0
        var batteryToLoad = 0.0
        var chargeW = 0.0

        if let input = adapterInW {
            adapterToLoad = min(input, load)
            batteryToLoad = max(0, load - input)
            chargeW = max(0, input - load)
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

        // 台式机没有电池：全部负载来自电源。
        // （PSTR 比 PDTR 慢一个采样周期，直接相减会凭空出现 0.x W 的“电池供电”）
        if !hasBattery {
            adapterToLoad = load
            batteryToLoad = 0
            chargeW = 0
        }

        //  Attribution deadband（有电池、接着电源）：
        // 采样相位差造成的 ±0.7 W 抖动不要显示成电池在供电/充电。
        if hasBattery, onAC, batteryToLoad < 0.7 {
            adapterToLoad = load
            batteryToLoad = 0
        }
        if hasBattery, onAC, chargeW < 0.7 {
            chargeW = 0
        }

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
        let portW: Double? = raw.portTelemetryAvailable != 0 ? raw.portPower_W : nil
        func temp(_ value: Double) -> Double? {
            value.isFinite && value > -20 && value < 150 ? value : nil
        }
        let fanW: Double? = raw.fanAvailable != 0 ? raw.fanRPM : nil
        let fanMin: Double? = raw.fanAvailable != 0 && raw.fanMinRPM > 0 ? raw.fanMinRPM : nil
        let fanMax: Double? = raw.fanAvailable != 0 && raw.fanMaxRPM > 0 ? raw.fanMaxRPM : nil

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
            inputVoltageV: inputV,
            inputCurrentA: inputA,
            cpuTempC: temp(raw.cpuTempC),
            gpuTempC: temp(raw.gpuTempC),
            ssdTempC: temp(raw.ssdTempC),
            batteryTempC: temp(raw.batteryTempC),
            platformTempC: temp(raw.platformTempC),
            fanRPM: fanW,
            fanMinRPM: fanMin,
            fanMaxRPM: fanMax,
            source: dataSource
        )
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

    /// 把电流符号的实测值，按“充电为正、放电为负”归一化。
    private func normalizeBatteryPower(_ measured: Double, charging: Bool,
                                       onAC: Bool, charged: Bool) -> Double {
        if charging { return abs(measured) }
        if onAC { return charged ? 0 : abs(measured) }
        return -abs(measured)
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
}
