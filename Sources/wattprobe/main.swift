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
var splitTest = false
var batteryReport = false

var positional: [String] = []
var index = 1
while index < CommandLine.arguments.count {
    let arg = CommandLine.arguments[index]
    switch arg {
    case "--json":
        asJSON = true
    case "--keys":
        listKeys = true
    case "--split-test":
        splitTest = true
    case "--battery":
        batteryReport = true
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

if splitTest {
    var failed = 0
    func check(_ name: String, _ got: PowerReader.PowerSplit, _ want: (Double, Double, Double)) {
        let ok = abs(got.adapterToLoad - want.0) < 0.01
              && abs(got.batteryToLoad - want.1) < 0.01
              && abs(got.charge - want.2) < 0.01
        print(String(format: "  %@ %-38s adapter=%5.1f battery=%5.1f charge=%5.1f",
                     ok ? "PASS" : "FAIL", (name as NSString).utf8String ?? "",
                     got.adapterToLoad, got.batteryToLoad, got.charge))
        if !ok { failed += 1 }
    }
    print("功率分流自检（电源 / 电池 / 充电）：")
    // 台式机：无电池，全部来自电源
    check("desktop, no battery", PowerReader.split(input: 12, load: 12, hasBattery: false, onAC: true), (12, 0, 0))
    // 笔记本：接电且充电
    check("laptop charging 65W", PowerReader.split(input: 65, load: 30, hasBattery: true, onAC: true), (30, 0, 35))
    // 笔记本：混合供电（45W 适配器 + 52W 负载）
    check("hybrid: 45W adapter, 52W load", PowerReader.split(input: 45, load: 52, hasBattery: true, onAC: true), (45, 7, 0))
    // 笔记本：纯电池放电
    check("battery only 20W", PowerReader.split(input: nil, load: 20, hasBattery: true, onAC: false), (0, 20, 0))
    // 笔记本：接电已充满
    check("on AC, fully charged", PowerReader.split(input: 14, load: 14, hasBattery: true, onAC: true), (14, 0, 0))
    // 死区：0.6W 的相位差不应显示为电池供电
    check("dead band 0.6W", PowerReader.split(input: 20.4, load: 21.0, hasBattery: true, onAC: true), (21, 0, 0))
    // 弱充电器 + 大负载：电池补足大部分
    check("hybrid: 20W adapter, 60W load", PowerReader.split(input: 20, load: 60, hasBattery: true, onAC: true), (20, 40, 0))
    // 刚拔掉电源：PDTR 可能残留，不能被当成电源供电
    check("unplugged, stale PDTR", PowerReader.split(input: 45, load: 20, hasBattery: true, onAC: false), (0, 20, 0))
    // 刚插上电源、数据还没更新
    check("plugged in, no input yet", PowerReader.split(input: nil, load: 20, hasBattery: true, onAC: true), (20, 0, 0))
    print(failed == 0 ? "全部通过" : "有 \(failed) 项失败")
    exit(failed == 0 ? 0 : 1)
}

if batteryReport {
    guard let r = reader.read() else {
        print("读取失败：没有可用数据")
        exit(1)
    }
    func f(_ v: Double?, _ digits: Int = 2) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.\(digits)f", v)
    }
    func smc(_ key: String) -> String {
        guard let v = reader.smcFloat(key) else { return "—" }
        return f(v)
    }
    print("== WattMeter 电池机型诊断 ==")
    print("电池安装: \(r.hasBattery ? "是" : "否")   外部电源: \(r.onAC ? "是" : "否")   充电中: \(r.isCharging ? "是" : "否")   已充满: \(r.isCharged ? "是" : "否")")
    print("电池电压: \(f(r.batteryVoltageV)) V   电池电流: \(f(r.batteryCurrentA)) A   （负值 = 放电）")
    func remainingText(_ minutes: Double?) -> String {
        guard let minutes, minutes > 0 else { return "—" }
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分钟"
    }
    print("电量: \(r.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "—")   剩余: \(remainingText(r.timeRemainingMinutes))")
    print("适配器: 额定 \(f(r.adapterRatedW, 0)) W   名称: \(r.adapterName ?? "—")")
    print("SMC : PSTR=\(smc("PSTR"))W  PDTR=\(smc("PDTR"))W  VD0R=\(smc("VD0R"))V  ID0R=\(smc("ID0R"))A")
    print("SMC 电池键: B0AV=\(smc("B0AV"))  B0AC=\(smc("B0AC"))  TB0T=\(smc("TB0T"))")
    print("分流: 电源→负载 \(f(r.adapterToLoadW)) W   电池→负载 \(f(r.batteryToLoadW)) W   充电 \(f(r.chargeW)) W")
    print("净功率: 电池 \(f(r.batteryPowerW)) W   适配器输入 \(f(r.adapterInputW)) W   整机 \(f(r.totalW)) W")
    print("分项: 系统 \(f(r.systemComponentW)) W   屏幕 \(f(r.displayPowerW)) W   接口 \(f(r.portPowerW)) W")
    print("温度: CPU \(f(r.cpuTempC, 1))  GPU \(f(r.gpuTempC, 1))  SSD \(f(r.ssdTempC, 1))  电池 \(f(r.batteryTempC, 1))  平台 \(f(r.platformTempC, 1))")
    print("风扇: \(r.fanText) RPM")
    let state: String
    if !r.hasBattery { state = "台式机（无电池）" }
    else if !r.onAC { state = "纯电池供电" }
    else if r.isCharging { state = "充电中（电源供电 + 电池充电）" }
    else if r.isHybrid { state = "混合供电（电源不足，电池补足）" }
    else { state = r.isCharged ? "外接电源（已充满）" : "外接电源（待机）" }
    print("判定: \(state)")
    if r.hasBattery, r.batteryPercent == nil {
        print("提示: 读不到电池电量，可能 IOPS 未返回内部电池信息。")
    }
    if r.hasBattery, r.batteryPowerW == nil {
        print("提示: 读不到电池净功率，Amperage/InstantAmperage 可能为 0 或类型异常。")
    }
    if r.hasBattery, r.onAC, !r.isCharging, r.batteryToLoadW > 0.5 {
        print("提示: 检测到混合供电，请对照系统「电池」面板确认电池正在放电。")
    }
    if r.hasBattery, r.batteryVoltageV == nil {
        print("提示: 电池电压异常（Voltage 字段缺失或超出 1–30V）。")
    }
    exit(0)
}

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
