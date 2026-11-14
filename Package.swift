// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WattMeter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WattMeter", targets: ["WattMeter"]),
        .executable(name: "wattprobe", targets: ["wattprobe"]),
        .executable(name: "wattmeter-snapshot", targets: ["wattmeter-snapshot"]),
    ],
    targets: [
        // C 桥接层：AppleSMC 用户客户端 + IORegistry(AppleSmartBattery) + IOPS
        .target(
            name: "CSystemPower",
            path: "Sources/CSystemPower",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // 数据模型、采样器、派生功率计算
        .target(name: "WattMeterCore", dependencies: ["CSystemPower"], path: "Sources/WattMeterCore"),
        // SwiftUI 界面（菜单栏面板 + 主窗口）
        .target(name: "WattMeterUI", dependencies: ["WattMeterCore"], path: "Sources/WattMeterUI"),
        // 菜单栏 App
        .executableTarget(name: "WattMeter", dependencies: ["WattMeterUI", "WattMeterCore"], path: "Sources/WattMeter"),
        // 命令行探针：在真机上核对数据源
        .executableTarget(name: "wattprobe", dependencies: ["WattMeterCore"], path: "Sources/wattprobe"),
        // 离屏渲染预览图（无需屏幕录制权限）
        .executableTarget(name: "wattmeter-snapshot", dependencies: ["WattMeterUI"], path: "Sources/wattmeter-snapshot"),
    ]
)
