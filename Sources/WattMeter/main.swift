import AppKit
import WattMeterCore
import WattMeterUI

// 命令行诊断（DMG 里的 App 也能直接跑，不需要开发工具）
if CommandLine.arguments.contains("--chips") {
    print(Diagnostics.chips())
    exit(0)
}
if CommandLine.arguments.contains("--fans") {
    print(Diagnostics.fans())
    exit(0)
}
if CommandLine.arguments.contains("--battery") {
    print(Diagnostics.battery())
    exit(0)
}
if CommandLine.arguments.contains("--ssd") {
    print(Diagnostics.ssd())
    exit(0)
}
if CommandLine.arguments.contains("--disk") {
    print(Diagnostics.disk())
    exit(0)
}
if CommandLine.arguments.contains("--battery-keys") {
    print(Diagnostics.batteryKeys())
    exit(0)
}
if CommandLine.arguments.contains("--split-test") {
    let result = Diagnostics.splitTest()
    print(result.text)
    exit(result.failed == 0 ? 0 : 1)
}

// --menubar-test：不打开界面，打印菜单栏在各种口径下会显示的文字
if CommandLine.arguments.contains("--menubar-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let store = PowerStore()
    store.start()
    let deadline = Date().addingTimeInterval(2.5)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard let latest = store.latest else {
        print("menubar-test FAILED: 没有读到功率数据")
        exit(1)
    }
    print("current metric=\(MenuBarMetric(rawValue: UserDefaults.standard.string(forKey: MenuBarMetric.defaultsKey) ?? "")?.rawValue ?? "adapterInput(default)")")
    for metric in MenuBarMetric.allCases {
        print("  \(metric.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(metric.text(for: latest))")
    }
    print(String(format: "  readings: system=%.2f input=%.2f wall=%.2f battery=%.2f",
                 latest.totalW, latest.adapterInputW ?? -1,
                 latest.wallPowerW ?? -1, latest.batteryPowerW ?? 0))
    exit(0)
}

// --login-item：命令行查看/开关登录项（便于验证与自动化）
if CommandLine.arguments.contains("--login-item") {
    LoginItemController().handleCommandLine()
}

// --selftest：不打开界面，运行采样器 3.5 秒后打印结果并退出。
// 用于在无 GUI 观察条件下验证 App 的完整数据链路。
if CommandLine.arguments.contains("--selftest") {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    let store = PowerStore()
    store.start()

    let deadline = Date().addingTimeInterval(3.5)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    if let latest = store.latest {
        print("selftest OK: \(String(format: "%.1f", latest.totalW)) W, 来源=\(latest.source.label), 样本=\(store.history.count)")
        print("  input: \(latest.inputRailsText ?? "—")")
        print("  fanRPM=\(latest.fanRPM.map { String(format: "%.0f", $0) } ?? "—")")
        print("  temps: CPU=\(latest.cpuTempC.map { String(format: "%.1f", $0) } ?? "—")"
              + " GPU=\(latest.gpuTempC.map { String(format: "%.1f", $0) } ?? "—")"
              + " SSD=\(latest.ssdTempC.map { String(format: "%.1f", $0) } ?? "—")"
              + " BAT=\(latest.batteryTempC.map { String(format: "%.1f", $0) } ?? "—")"
              + " PLATFORM=\(latest.platformTempC.map { String(format: "%.1f", $0) } ?? "—")")
        print(String(format: "  system=%.2f W  display=%.2f W  ports=%.2f W",
                     latest.systemComponentW,
                     latest.displayPowerW ?? -1,
                     latest.portPowerW ?? -1))
        print(String(format: "  adapterIn=%.2f W  battery=%.2f W  wall=%.2f W  hasBattery=%@  onAC=%@",
                     latest.adapterInputW ?? -1,
                     latest.batteryPowerW ?? 0,
                     latest.wallPowerW ?? -1,
                     latest.hasBattery ? "Y" : "N",
                     latest.onAC ? "Y" : "N"))
        exit(0)
    } else {
        print("selftest FAILED: 没有读到功率数据")
        exit(1)
    }
}

// 菜单栏常驻应用（Info.plist 里 LSUIElement = true，不显示 Dock 图标）
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
