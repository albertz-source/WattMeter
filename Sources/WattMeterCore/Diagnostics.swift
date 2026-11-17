import Foundation

/// 命令行诊断输出（App 与 wattprobe 共用）。
public enum Diagnostics {
    // MARK: - 风扇

    public static func fans() -> String {
        let reader = PowerReader()
        var lines: [String] = ["== 风扇 SMC 键 =="]
        let dump = reader.dumpFanKeys()
        if dump.isEmpty {
            lines.append("未发现任何 F 开头的风扇键")
        } else {
            lines.append(dump.trimmingCharacters(in: .newlines))
        }
        if let r = reader.read() {
            let rpm = r.fanRPM.map { String(format: "%.0f RPM", $0) } ?? "—"
            let target = r.fanTargetRPM.map { String(format: "%.0f RPM", $0) } ?? "—"
            lines.append("识别到风扇: \(r.fanCount ?? 0) 个，当前 \(rpm)，目标 \(target)")
            if let min = r.fanMinRPM, let max = r.fanMaxRPM {
                lines.append(String(format: "转速范围: %.0f–%.0f RPM", min, max))
            }
            if let rpm = r.fanRPM, rpm < 1, (r.fanMinRPM ?? 0) > 0 {
                lines.append("提示: 当前风扇转速为 0 —— M3/M4 MacBook 空闲时热管理会完全停转，属正常现象。")
            }
            if r.fanRPM == nil {
                lines.append("提示: 没有可解码的 F?Ac 键，请把上面的键列表反馈给作者。")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 电池

    public static func battery() -> String {
        let reader = PowerReader()
        guard let r = reader.read() else { return "读取失败：没有可用数据" }

        func f(_ v: Double?, _ digits: Int = 2) -> String {
            guard let v, v.isFinite else { return "—" }
            return String(format: "%.\(digits)f", v)
        }
        func smc(_ key: String) -> String {
            guard let v = reader.smcFloat(key) else { return "—" }
            return f(v)
        }
        func remainingText(_ minutes: Double?) -> String {
            guard let minutes, minutes > 0 else { return "—" }
            let m = Int(minutes.rounded())
            return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分钟"
        }

        var lines: [String] = ["== WattMeter 电池机型诊断 =="]
        lines.append("电池安装: \(r.hasBattery ? "是" : "否")   外部电源: \(r.onAC ? "是" : "否")   "
                     + "充电中: \(r.isCharging ? "是" : "否")   已充满: \(r.isCharged ? "是" : "否")")
        lines.append("电池电压: \(f(r.batteryVoltageV)) V   电池电流: \(f(r.batteryCurrentA)) A   （负值 = 放电）")
        lines.append("电量: \(r.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "—")   "
                     + "剩余: \(remainingText(r.timeRemainingMinutes))")
        lines.append("适配器: 额定 \(f(r.adapterRatedW, 0)) W   名称: \(r.adapterName ?? "—")")
        lines.append("SMC : PSTR=\(smc("PSTR"))W  PDTR=\(smc("PDTR"))W  VD0R=\(smc("VD0R"))V  ID0R=\(smc("ID0R"))A")
        lines.append("SMC 电池键: B0AV=\(smc("B0AV"))  B0AC=\(smc("B0AC"))  TB0T=\(smc("TB0T"))")
        lines.append("分流: 电源→负载 \(f(r.adapterToLoadW)) W   电池→负载 \(f(r.batteryToLoadW)) W   "
                     + "充电 \(f(r.chargeW)) W")
        lines.append("净功率: 电池 \(f(r.batteryPowerW)) W   适配器输入 \(f(r.adapterInputW)) W   "
                     + "整机 \(f(r.totalW)) W")
        lines.append("分项: 系统 \(f(r.systemComponentW)) W   屏幕 \(f(r.displayPowerW)) W   接口 \(f(r.portPowerW)) W")
        lines.append("温度: CPU \(f(r.cpuTempC, 1))  GPU \(f(r.gpuTempC, 1))  SSD \(f(r.ssdTempC, 1))  "
                     + "电池 \(f(r.batteryTempC, 1))  平台 \(f(r.platformTempC, 1))")
        lines.append("风扇: \(r.fanText) RPM（\(r.fanCount ?? 0) 个）")

        let state: String
        if !r.hasBattery {
            state = "台式机（无电池）"
        } else if !r.onAC {
            state = "纯电池供电"
        } else if r.isCharging {
            state = "充电中（电源供电 + 电池充电）"
        } else if r.isHybrid {
            state = "混合供电（电源不足，电池补足）"
        } else {
            state = r.isCharged ? "外接电源（已充满）" : "外接电源（待机）"
        }
        lines.append("判定: \(state)")

        if r.hasBattery, r.batteryPercent == nil {
            lines.append("提示: 读不到电池电量，可能 IOPS 未返回内部电池信息。")
        }
        if r.hasBattery, r.batteryPowerW == nil {
            lines.append("提示: 读不到电池净功率，Amperage/InstantAmperage 可能为 0 或类型异常。")
        }
        if r.hasBattery, r.onAC, !r.isCharging, r.batteryToLoadW > 0.5 {
            lines.append("提示: 检测到混合供电，请对照系统「电池」面板确认电池正在放电。")
        }
        if r.hasBattery, r.batteryVoltageV == nil {
            lines.append("提示: 电池电压异常（Voltage 字段缺失或超出 1–30V）。")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 分流自检

    public static func splitTest() -> (text: String, failed: Int) {
        var failed = 0
        var lines: [String] = ["功率分流自检（电源 / 电池 / 充电）："]
        func check(_ name: String, _ got: PowerReader.PowerSplit, _ want: (Double, Double, Double)) {
            let ok = abs(got.adapterToLoad - want.0) < 0.01
                && abs(got.batteryToLoad - want.1) < 0.01
                && abs(got.charge - want.2) < 0.01
            if !ok { failed += 1 }
            lines.append(String(format: "  %@ %-34s adapter=%5.1f battery=%5.1f charge=%5.1f",
                                ok ? "PASS" : "FAIL", (name as NSString).utf8String ?? "",
                                got.adapterToLoad, got.batteryToLoad, got.charge))
        }
        check("desktop, no battery", PowerReader.split(input: 12, load: 12, hasBattery: false, onAC: true), (12, 0, 0))
        check("laptop charging 65W", PowerReader.split(input: 65, load: 30, hasBattery: true, onAC: true), (30, 0, 35))
        check("hybrid: 45W adapter, 52W load", PowerReader.split(input: 45, load: 52, hasBattery: true, onAC: true), (45, 7, 0))
        check("battery only 20W", PowerReader.split(input: nil, load: 20, hasBattery: true, onAC: false), (0, 20, 0))
        check("on AC, fully charged", PowerReader.split(input: 14, load: 14, hasBattery: true, onAC: true), (14, 0, 0))
        check("dead band 0.6W", PowerReader.split(input: 20.4, load: 21.0, hasBattery: true, onAC: true), (21, 0, 0))
        check("hybrid: 20W adapter, 60W load", PowerReader.split(input: 20, load: 60, hasBattery: true, onAC: true), (20, 40, 0))
        check("unplugged, stale PDTR", PowerReader.split(input: 45, load: 20, hasBattery: true, onAC: false), (0, 20, 0))
        check("plugged in, no input yet", PowerReader.split(input: nil, load: 20, hasBattery: true, onAC: true), (20, 0, 0))
        lines.append(failed == 0 ? "全部通过" : "有 \(failed) 项失败")
        return (lines.joined(separator: "\n"), failed)
    }
}
