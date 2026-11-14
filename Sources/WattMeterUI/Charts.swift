import SwiftUI
import Charts
import WattMeterCore

// 说明：本机（macOS 27 + Swift Charts）在离屏渲染时，多个独立的 mark 语句
// 只会画出第一个。因此这里统一使用“长表数据 + foregroundStyle(by:)”的
// 单 ForEach 写法，既符合 Swift Charts 的惯用法，也能稳定渲染。

private struct AreaRow: Identifiable {
    let id: String
    let time: Date
    let series: String
    let watts: Double
}

// MARK: - 堆叠面积图：功率来源（电源 / 电池）

public struct SourceAreaChart: View {
    let readings: [PowerReading]
    var height: CGFloat

    public init(readings: [PowerReading], height: CGFloat = 150) {
        self.readings = readings
        self.height = height
    }

    public var body: some View {
        let rows = Self.rows(readings)
        let peak = readings.map { $0.adapterToLoadW + $0.batteryToLoadW }.max() ?? 0
        let maxY = max(20, ceil(peak / 10) * 10)

        Chart(rows) { row in
            AreaMark(
                x: .value("时间", row.time),
                y: .value("功率", row.watts),
                stacking: .standard
            )
            .foregroundStyle(by: .value("来源", row.series))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale([
            "电源": Palette.adapter,
            "电池": Palette.battery,
        ])
        .chartLegend(.hidden)
        .chartYScale(domain: 0...maxY)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v)) W").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
        }
        .frame(height: height)
    }

    private static func rows(_ readings: [PowerReading]) -> [AreaRow] {
        var rows: [AreaRow] = []
        rows.reserveCapacity(readings.count * 2)
        for (index, reading) in readings.enumerated() {
            rows.append(AreaRow(id: "\(index)-a", time: reading.timestamp,
                                series: "电源", watts: reading.adapterToLoadW))
            rows.append(AreaRow(id: "\(index)-b", time: reading.timestamp,
                                series: "电池", watts: reading.batteryToLoadW))
        }
        return rows
    }
}

// MARK: - 紧凑趋势条（面板内使用，无坐标轴）

public struct TrendSparkline: View {
    let readings: [PowerReading]
    var height: CGFloat

    public init(readings: [PowerReading], height: CGFloat = 52) {
        self.readings = readings
        self.height = height
    }

    public var body: some View {
        let rows = rows(readings)
        let peak = readings.map { $0.adapterToLoadW + $0.batteryToLoadW }.max() ?? 0
        let maxY = max(10, ceil(peak / 10) * 10)

        Chart(rows) { row in
            AreaMark(
                x: .value("时间", row.time),
                y: .value("功率", row.watts),
                stacking: .standard
            )
            .foregroundStyle(by: .value("来源", row.series))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale([
            "电源": Palette.mint,
            "电池": Palette.amber,
        ])
        .chartLegend(.hidden)
        .chartYScale(domain: 0...maxY)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }

    private struct Row: Identifiable {
        let id: String
        let time: Date
        let series: String
        let watts: Double
    }

    private func rows(_ readings: [PowerReading]) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(readings.count * 2)
        for (index, reading) in readings.enumerated() {
            rows.append(Row(id: "\(index)-a", time: reading.timestamp, series: "电源", watts: reading.adapterToLoadW))
            rows.append(Row(id: "\(index)-b", time: reading.timestamp, series: "电池", watts: reading.batteryToLoadW))
        }
        return rows
    }
}

// MARK: - 折线图：整机功耗 / 电池净功率

private struct LineRow: Identifiable {
    let id: String
    let time: Date
    let series: String
    let watts: Double
}

public struct PowerLineChart: View {
    let readings: [PowerReading]
    var height: CGFloat

    public init(readings: [PowerReading], height: CGFloat = 130) {
        self.readings = readings
        self.height = height
    }

    public var body: some View {
        let rows = Self.rows(readings)
        let peak = max(20, (readings.map(\.totalW).max() ?? 0) * 1.15)
        let low = min(0, (readings.compactMap(\.batteryPowerW).min() ?? 0) * 1.15)

        Chart(rows) { row in
            LineMark(
                x: .value("时间", row.time),
                y: .value("功率", row.watts)
            )
            .foregroundStyle(by: .value("系列", row.series))
            .lineStyle(StrokeStyle(lineWidth: row.series == "整机功耗" ? 2 : 1.5,
                                   lineCap: .round,
                                   dash: row.series == "整机功耗" ? [] : [4, 3]))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale([
            "整机功耗": Palette.adapter,
            "电池净功率": Palette.battery,
        ])
        .chartLegend(.hidden)
        .chartYScale(domain: low...peak)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v)) W").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
        }
        .frame(height: height)
    }

    private static func rows(_ readings: [PowerReading]) -> [LineRow] {
        var rows: [LineRow] = []
        rows.reserveCapacity(readings.count * 2)
        for (index, reading) in readings.enumerated() {
            rows.append(LineRow(id: "\(index)-t", time: reading.timestamp,
                                series: "整机功耗", watts: reading.totalW))
            rows.append(LineRow(id: "\(index)-b", time: reading.timestamp,
                                series: "电池净功率", watts: reading.batteryPowerW ?? 0))
        }
        return rows
    }
}
