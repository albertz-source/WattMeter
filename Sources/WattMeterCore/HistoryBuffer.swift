import Foundation

/// 固定容量的采样历史缓冲，并顺带积分出本次会话的用电量（Wh）。
public struct HistoryBuffer {
    public private(set) var samples: [PowerReading] = []
    public let capacity: Int
    private var energyWh: Double = 0
    private var lastSample: PowerReading?

    public init(capacity: Int = 3600) {
        self.capacity = capacity
    }

    public mutating func append(_ reading: PowerReading) {
        if let last = lastSample {
            let dt = reading.timestamp.timeIntervalSince(last.timestamp)
            // 只对正常的 1Hz 左右的样本积分，避免唤醒/休眠造成巨大跳变
            if dt > 0, dt < 10 {
                energyWh += last.totalW * dt / 3600.0
            }
        }
        lastSample = reading
        samples.append(reading)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// 取最近 seconds 秒的样本
    public func window(_ seconds: TimeInterval, now: Date = Date()) -> [PowerReading] {
        let cutoff = now.addingTimeInterval(-seconds)
        return samples.filter { $0.timestamp >= cutoff }
    }

    public var sessionEnergyWh: Double { energyWh }

    public var averageW: Double? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0) { $0 + $1.totalW } / Double(samples.count)
    }

    public var peakW: Double? {
        samples.map(\.totalW).max()
    }
}
