import Foundation
import WattMeterCore

// wattprobe：命令行数据源探针
//   wattprobe              每秒打印一次，共 10 次
//   wattprobe 30 1         采样 30 次，间隔 1 秒
//   wattprobe --keys       列出候选 SMC 功率键及读数
//   wattprobe --json 5     以 JSON Lines 输出 5 条

var count = 10
var interval: TimeInterval = 1.0
var asJSON = false
var listKeys = false

var positional: [String] = []
var index = 1
while index < CommandLine.arguments.count {
    let arg = CommandLine.arguments[index]
    switch arg {
    case "--json":
        asJSON = true
    case "--keys":
        listKeys = true
    case "--interval", "-i":
        index += 1
        if index < CommandLine.arguments.count, let v = Double(CommandLine.arguments[index]) {
            interval = v
        }
    case "--help", "-h":
        print("""
        wattprobe — WattMeter 数据源探针

        用法:
          wattprobe [次数] [间隔秒] [--json] [--keys]

        示例:
          wattprobe            # 打印 10 次，每秒一次
          wattprobe 60 0.5     # 打印 60 次，每 0.5 秒一次
          wattprobe --keys     # 列出候选 SMC 键
        """)
        exit(0)
    default:
        positional.append(arg)
    }
    index += 1
}

if positional.count > 0, let v = Int(positional[0]) { count = max(1, v) }
if positional.count > 1, let v = Double(positional[1]) { interval = max(0.05, v) }

let reader = PowerReader()

if listKeys {
    print("候选 SMC 键（flt 类型，单位 W）：")
    let candidates = ["PSTR", "PDTR", "PD0R", "PPBR", "PBwo", "PDBR", "PCPR", "PHPC",
                      "PZC0", "PZC1", "PZD0", "PZD1", "PZD2", "PZD3",
                      "TB0T", "Ts0P", "Ts1P", "TsOP"]
    for key in candidates {
        if let value = reader.smcFloat(key) {
            print(String(format: "  %-6s = %8.2f W", (key as NSString).utf8String!, value))
        } else {
            print("  \(key)    = （不存在或不是 flt）")
        }
    }
    print("\n提示：PSTR 通常是整机功耗，PDTR 是适配器 DC 输入，PD0R 是台式机 DC 输入。")
    exit(0)
}

if asJSON {
    let formatter = ISO8601DateFormatter()
    for i in 0..<count {
        if let reading = reader.read() {
            let dict: [String: Any] = [
                "t": formatter.string(from: reading.timestamp),
                "total_w": reading.totalW,
                "adapter_in_w": reading.adapterInputW ?? 0,
                "battery_w": reading.batteryPowerW ?? 0,
                "adapter_to_load_w": reading.adapterToLoadW,
                "battery_to_load_w": reading.batteryToLoadW,
                "charge_w": reading.chargeW,
                "wall_w": reading.wallPowerW ?? 0,
                "soc": reading.batteryPercent ?? -1,
                "on_ac": reading.onAC,
                "charging": reading.isCharging,
                "has_battery": reading.hasBattery,
                "source": reading.source.rawValue,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let line = String(data: data, encoding: .utf8) {
                print(line)
            }
        } else {
            print("{\"error\":\"no data\"}")
        }
        if i != count - 1 { Thread.sleep(forTimeInterval: interval) }
    }
    exit(0)
}

print("时间         整机     电源输入   电池( +充/-放 )  电源→负载  电池→负载  电量   状态")
print(String(repeating: "─", count: 92))
let timeFormatter = DateFormatter()
timeFormatter.dateFormat = "HH:mm:ss"

for i in 0..<count {
    if let r = reader.read() {
        let time = timeFormatter.string(from: r.timestamp)
        let total = String(format: "%6.1f", r.totalW)
        let adapterIn = r.adapterInputW.map { String(format: "%6.1f", $0) } ?? "     —"
        let battery = r.batteryPowerW.map { String(format: "%+7.1f", $0) } ?? "      —"
        let adapterLoad = String(format: "%7.1f", r.adapterToLoadW)
        let batteryLoad = String(format: "%7.1f", r.batteryToLoadW)
        let soc = r.batteryPercent.map { String(format: "%4.0f%%", $0) } ?? "   —"
        print("\(time)  \(total)  \(adapterIn)  \(battery)      \(adapterLoad)  \(batteryLoad)  \(soc)   \(r.batteryStateText)  [\(r.source.label)]")
    } else {
        print("读取失败：没有可用的功率数据源")
    }
    if i != count - 1 { Thread.sleep(forTimeInterval: interval) }
}
