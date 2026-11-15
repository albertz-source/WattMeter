import AppKit
import SwiftUI
import WattMeterCore
import WattMeterUI

// wattmeter-snapshot：不依赖屏幕录制权限，把界面离屏渲染成 PNG。
// 用法：wattmeter-snapshot --out preview.png [--width 380] [--scale 2]

var outPath: String?
var width: CGFloat = 380
var scale: CGFloat = 2
var viewName = "dashboard"
var stateName = "auto"
var langName: String?

var index = 1
while index < CommandLine.arguments.count {
    let arg = CommandLine.arguments[index]
    switch arg {
    case "--out":
        index += 1
        if index < CommandLine.arguments.count { outPath = CommandLine.arguments[index] }
    case "--width":
        index += 1
        if index < CommandLine.arguments.count, let v = Double(CommandLine.arguments[index]) {
            width = CGFloat(v)
        }
    case "--scale":
        index += 1
        if index < CommandLine.arguments.count, let v = Double(CommandLine.arguments[index]) {
            scale = CGFloat(v)
        }
    case "--view":
        index += 1
        if index < CommandLine.arguments.count { viewName = CommandLine.arguments[index] }
    case "--state":
        index += 1
        if index < CommandLine.arguments.count { stateName = CommandLine.arguments[index] }
    case "--lang":
        index += 1
        if index < CommandLine.arguments.count { langName = CommandLine.arguments[index] }
    default:
        break
    }
    index += 1
}

guard let outPath else {
    print("用法: wattmeter-snapshot --out preview.png [--width 380] [--scale 2]")
    exit(2)
}

// 顶层代码运行在主线程上，这里显式进入 MainActor 以满足 SwiftUI 的隔离要求。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    RenderSettings.isPreviewing = true
    if let langName, let parsed = AppLanguage(rawValue: langName) {
        Localization.shared.setLanguage(parsed)
    }

    let store = PowerStore()
    let endPhase: Double?
    switch stateName {
    case "battery":  endPhase = 30   // 电池放电
    case "charging": endPhase = 70   // 接电源 + 充电
    case "ac":       endPhase = 90   // 接电源 + 已充满
    case "hybrid":   endPhase = 50   // 45W 适配器 + 高负载 → 电池补足
    default:         endPhase = nil
    }
    store.loadPreview(samples: DemoGenerator.history(seconds: 300, endPhase: endPhase))

    let content: AnyView
    if viewName == "main" {
        content = AnyView(MainWindowView(store: store, scrollable: false).frame(width: width))
    } else if viewName == "flow" {
        content = AnyView(
            FlowDiagram(reading: store.latest)
                .frame(width: 364, height: 180)
                .background(Color(red: 0.09, green: 0.11, blue: 0.13))
        )
    } else {
        content = AnyView(DashboardView(store: store).frame(width: width))
    }
    let renderer = ImageRenderer(content: content)
    renderer.scale = scale
    renderer.proposedSize = ProposedViewSize(width: width, height: nil)

    guard let cgImage = renderer.cgImage else {
        print("渲染失败：ImageRenderer 没有产生图像")
        exit(3)
    }

    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("PNG 编码失败")
        exit(4)
    }

    do {
        try data.write(to: URL(fileURLWithPath: outPath))
        print("已生成 \(outPath)（\(cgImage.width)×\(cgImage.height)）")
    } catch {
        print("写入失败：\(error.localizedDescription)")
        exit(5)
    }
}
