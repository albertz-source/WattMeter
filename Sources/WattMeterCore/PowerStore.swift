import Foundation

/// 后台采样器：用 DispatchSourceTimer 每秒读一次，读数回调在主线程。
public final class PowerSampler {
    public var interval: TimeInterval
    /// 在主线程回调
    public var onReading: ((PowerReading) -> Void)?
    /// 在主线程回调（读取失败）
    public var onFailure: (() -> Void)?

    private let queue = DispatchQueue(label: "com.wattmeter.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var reader: PowerReader?
    private var failureCount = 0

    public init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    public func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.05, repeating: interval, leeway: .milliseconds(120))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.reader == nil {
                self.reader = PowerReader()
            }
            guard let reader = self.reader else {
                self.reportFailure()
                return
            }
            if let reading = reader.read() {
                self.failureCount = 0
                DispatchQueue.main.async { self.onReading?(reading) }
            } else {
                self.reportFailure()
            }
        }
        source.resume()
        timer = source
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        reader = nil
    }

    private func reportFailure() {
        failureCount += 1
        guard failureCount <= 2 else { return }
        DispatchQueue.main.async { self.onFailure?() }
    }
}

/// 应用状态仓库：保存最新读数、历史、会话用电量。
///
/// 线程约定：所有 `@Published` 属性只在主线程修改；后台采样通过
/// `DispatchQueue.main.async` 回到主线程再写入。
public final class PowerStore: ObservableObject {
    @Published public private(set) var latest: PowerReading?
    @Published public private(set) var history: [PowerReading] = []
    @Published public private(set) var sessionEnergyWh: Double = 0
    @Published public private(set) var statusMessage: String = "正在读取功率…"
    /// 图表时间窗口（秒）
    @Published public private(set) var windowSeconds: Double = 300

    public let sampleInterval: TimeInterval

    private var buffer = HistoryBuffer(capacity: 3600)
    private let sampler = PowerSampler()

    public init(sampleInterval: TimeInterval = 1.0) {
        self.sampleInterval = sampleInterval
        sampler.interval = sampleInterval
        sampler.onReading = { [weak self] reading in
            self?.ingest(reading)
        }
        sampler.onFailure = { [weak self] in
            self?.statusMessage = "无法读取功率数据（可能被系统权限拦截）"
        }
    }

    deinit {
        sampler.stop()
    }

    // MARK: - 生命周期

    public func start() {
        statusMessage = "正在读取功率…"
        sampler.start()
    }

    public func stop() {
        sampler.stop()
    }

    /// 切换图表时间窗口
    public func setWindow(_ seconds: Double) {
        guard seconds > 0 else { return }
        windowSeconds = seconds
    }

    // MARK: - 数据

    private func ingest(_ reading: PowerReading) {
        buffer.append(reading)
        latest = reading
        history = buffer.samples
        sessionEnergyWh = buffer.sessionEnergyWh
        statusMessage = reading.source.label
    }

    public func readings(in window: TimeInterval) -> [PowerReading] {
        buffer.window(window)
    }

    public var averageW: Double? { buffer.averageW }
    public var peakW: Double? { buffer.peakW }

    /// 供离屏渲染 / 预览使用：直接灌入演示历史
    public func loadPreview(samples: [PowerReading]) {
        buffer = HistoryBuffer(capacity: 3600)
        for sample in samples { buffer.append(sample) }
        latest = samples.last
        history = buffer.samples
        sessionEnergyWh = buffer.sessionEnergyWh
        statusMessage = "演示数据"
    }
}
