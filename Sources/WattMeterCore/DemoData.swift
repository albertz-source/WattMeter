import Foundation

/// 演示数据生成器。
///
/// 台式机（如 Mac mini）没有电池，真实数据里看不到“电池 vs 电源”的拆分。
/// 演示模式会模拟一台笔记本在 110 秒周期内的典型场景：
///   电池空闲 → 电池满载 → 插电高负载 → 充电 → 充满外接
/// 这样在无电池机器上也能预览完整的 UI 与图表。
public struct DemoGenerator {
    private var rng: SeededRandom
    private var tick: Int = 0
    public let interval: TimeInterval
    /// 生成读数时是否包含芯片分项功率（用于预览「拿不到分项」的布局）
    public let includeChips: Bool

    public init(seed: UInt64 = 0x5EED_1234, interval: TimeInterval = 1.0,
                startTick: Int = 0, includeChips: Bool = true) {
        self.rng = SeededRandom(seed: seed)
        self.interval = interval
        self.tick = startTick
        self.includeChips = includeChips
    }

    /// 生成下一帧演示读数
    public mutating func next(now: Date = Date()) -> PowerReading {
        defer { tick += 1 }
        let t = Double(tick) * interval
        let cycle = t.truncatingRemainder(dividingBy: 110.0)

        // 阶段参数：phase → (系统负载, 是否接电, 是否充电, 电池电量, 是否混合供电)
        let phase: (load: Double, onAC: Bool, charging: Bool, soc: Double, hybrid: Bool)
        switch cycle {
        case ..<22:
            phase = (7.2, false, false, 62, false)
        case ..<42:
            phase = (28.5, false, false, 60, false)
        case ..<58:
            // 45W 适配器 + 52W 负载 → 电池补足，混合供电
            phase = (52.0, true, false, 58, true)
        case ..<82:
            phase = (15.0, true, true, 66, false)
        case ..<96:
            phase = (9.5, true, false, 84, false)
        default:
            phase = (7.8, true, false, 85, false)
        }

        let noise = rng.nextDouble(in: -0.8...0.8)
        let ripple = sin(t * 0.9) * 0.6
        let load = max(2.0, phase.load + noise + ripple)

        // 适配器：65W；混合供电阶段换成 45W 适配器
        let adapterLimit: Double = phase.hybrid ? 45.0 : 65.0
        var adapterIn: Double
        var batteryPower: Double
        var charging = phase.charging

        if phase.onAC {
            if phase.hybrid {
                adapterIn = min(load, adapterLimit)
                batteryPower = -(load - adapterIn)
                charging = false
            } else if phase.charging {
                let chargeRate = 18.0 + sin(t * 0.4) * 3.0
                adapterIn = load + chargeRate
                batteryPower = chargeRate
            } else {
                adapterIn = load + 0.2
                batteryPower = 0
            }
            // 电池接近充满时降低充电功率
            if phase.soc > 92 { batteryPower *= 0.3 }
        } else {
            adapterIn = 0
            batteryPower = -load
            charging = false
        }

        let system = load
        let adapterToLoad = phase.onAC ? min(adapterIn, load) : 0
        let batteryToLoad = max(0, load - adapterToLoad)
        let chargeW = max(0, adapterIn - load)
        let loss = adapterIn > 0 ? min(2.2, adapterIn * 0.055) : 0
        // 模拟 19.5 V 的适配器：电流 = 输入功率 / 电压
        let inputVoltage = 19.5
        let inputCurrent = adapterIn > 0 ? adapterIn / inputVoltage : 0

        // 电量缓慢变化
        let soc = min(100, max(3, phase.soc + sin(t * 0.05) * 0.8))

        // 分项功率（模拟笔记本：内置屏背光 + USB-C 对外供电）
        let display = min(max(1.2, load * 0.22), 4.6 + sin(t * 0.31) * 0.5)
        let port = min(max(0.4, load * 0.10), 2.2 + sin(t * 0.17) * 0.9)
        let safeDisplay = min(display, max(0, load - 1.2))
        let safePort = min(port, max(0, load - safeDisplay - 0.6))
        // 风扇：随负载线性上升，叠加一点波动（模拟 M 系列机型）
        let fan = min(4900, max(1700, 1700 + load * 62 + sin(t * 0.7) * 25))
        // 温度：CPU 随负载明显上升，SSD/电池/平台波动较小
        let cpuTemp = min(92, 38 + load * 0.85 + sin(t * 0.5) * 1.2)
        let gpuTemp = min(88, 35 + load * 0.55 + sin(t * 0.37) * 1.0)
        let ssdTemp = 34 + load * 0.06
        let batteryTemp = 29 + load * 0.12
        let platformTemp = 36 + load * 0.22

        return PowerReading(
            timestamp: now,
            systemPowerW: system,
            adapterInputW: adapterIn > 0 ? adapterIn : nil,
            batteryPowerW: batteryPower,
            adapterRatedW: adapterLimit,
            adapterName: phase.hybrid ? "45W USB-C 电源适配器" : "65W USB-C 电源适配器",
            wallPowerW: adapterIn > 0 ? adapterIn + loss : nil,
            adapterLossW: loss,
            adapterToLoadW: adapterToLoad,
            batteryToLoadW: batteryToLoad,
            chargeW: chargeW,
            hasBattery: true,
            onAC: phase.onAC,
            isCharging: charging && chargeW > 0.1,
            isCharged: phase.onAC && !charging && !phase.hybrid && soc > 80,
            batteryPercent: soc,
            timeRemainingMinutes: phase.onAC ? nil : (phase.load > 20 ? 95 : 380),
            displayPowerW: safeDisplay,
            portPowerW: safePort,
            cpuPowerW: includeChips ? load * 0.34 : nil,
            gpuPowerW: includeChips ? load * 0.16 : nil,
            anePowerW: includeChips ? 0.3 : nil,
            dramPowerW: includeChips ? load * 0.07 : nil,
            inputVoltageV: adapterIn > 0 ? inputVoltage : nil,
            inputCurrentA: adapterIn > 0 ? inputCurrent : nil,
            cpuTempC: cpuTemp,
            gpuTempC: gpuTemp,
            ssdTempC: ssdTemp,
            batteryTempC: batteryTemp,
            platformTempC: platformTemp,
            fanRPM: fan,
            fanCount: 2,
            fanMinRPM: 1700,
            fanMaxRPM: 4900,
            fanTargetRPM: fan,
            diskCount: 1,
            diskReadBytesPerSec: (6.0 + load * 0.22 + sin(t * 1.7) * 2.2) * 1_000_000,
            diskWriteBytesPerSec: (1.2 + load * 0.08 + abs(sin(t * 0.9)) * 1.1) * 1_000_000,
            diskReadBytesTotal: 1.535e12,
            diskWriteBytesTotal: 3.231e11,
            diskFreeBytes: 420.3e9,
            diskTotalBytes: 994.7e9,
            batteryDesignCapacityMAh: 6075,
            batteryFullChargeCapacityMAh: 5640,
            batteryCycleCount: 213,
            batteryDesignCycleCount: 1000,
            batteryHealthLabel: "Good",
            batteryHealthCondition: "Normal",
            source: .synthetic
        )
    }

    /// 预生成一段历史，供离屏渲染预览图使用。
    /// - Parameter endPhase: 让最后一个样本落在周期内的指定秒数（用于渲染“充电中/放电中”等固定状态）。
    public static func history(seconds: Int, seed: UInt64 = 0x5EED_1234,
                               endingAt now: Date = Date(),
                               endPhase: Double? = nil,
                               includeChips: Bool = true) -> [PowerReading] {
        let cycle = 110.0
        var lastTick = (seconds - 1) % 110
        if let endPhase {
            lastTick = Int(endPhase.truncatingRemainder(dividingBy: cycle))
        }
        let startTick = ((lastTick - (seconds - 1)) % Int(cycle) + Int(cycle)) % Int(cycle)
        var generator = DemoGenerator(seed: seed, startTick: startTick, includeChips: includeChips)
        var result: [PowerReading] = []
        for i in 0..<seconds {
            let time = now.addingTimeInterval(Double(i - seconds + 1))
            result.append(generator.next(now: time))
        }
        return result
    }
}

/// 可复现的伪随机数（避免每次预览图长得不一样）
public struct SeededRandom {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    public mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() % 1_000_000) / 1_000_000.0
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
