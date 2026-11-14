//
//  make-icon.swift
//  生成 WattMeter 的 .icns 素材（先输出 .iconset 里的多尺寸 PNG，再由 iconutil 打包）
//  用法：make-icon <输出 .iconset 目录>
//

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("用法: make-icon <WattMeter.iconset 目录>\n".utf8))
    exit(2)
}
let iconsetURL = URL(fileURLWithPath: args[1])
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let masterSize: CGFloat = 1024

/// 画一张 1024 的主图：深色圆角底 + 薄荷绿闪电 + 微光
func makeMaster() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(masterSize), pixelsHigh: Int(masterSize),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: masterSize, height: masterSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let canvas = NSRect(x: 0, y: 0, width: masterSize, height: masterSize)
    let inset: CGFloat = 56
    let shape = NSBezierPath(roundedRect: canvas.insetBy(dx: inset, dy: inset),
                             xRadius: 215, yRadius: 215)

    // 深色渐变底（与面板一致）
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.17, alpha: 1),
        NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.08, alpha: 1),
    ])!
    gradient.draw(in: shape, angle: -50)

    // 细描边
    NSColor(white: 1, alpha: 0.09).setStroke()
    shape.lineWidth = 3
    shape.stroke()

    // 中心微光
    if let glow = NSGradient(colors: [
        NSColor(calibratedRed: 0.43, green: 0.88, blue: 0.76, alpha: 0.16),
        NSColor(calibratedRed: 0.43, green: 0.88, blue: 0.76, alpha: 0.0),
    ]) {
        let glowRect = canvas.insetBy(dx: 250, dy: 250)
        glow.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
    }

    // 闪电符号（薄荷绿）
    let tint = NSColor(calibratedRed: 0.43, green: 0.88, blue: 0.76, alpha: 1)
    let base = NSImage.SymbolConfiguration(pointSize: 520, weight: .semibold)
    let colored = NSImage.SymbolConfiguration(paletteColors: [tint])
    let config = base.applying(colored)

    if let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        var size = symbol.size
        let scale = min(560 / max(size.width, 1), 560 / max(size.height, 1), 1.35)
        size = NSSize(width: size.width * scale, height: size.height * scale)
        let target = NSRect(
            x: (masterSize - size.width) / 2,
            y: (masterSize - size.height) / 2 - 8,
            width: size.width,
            height: size.height
        )
        let shadow = NSShadow()
        shadow.shadowColor = tint.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 46
        shadow.shadowOffset = .zero
        shadow.set()
        symbol.draw(in: target)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let masterRep = makeMaster()
let masterImage = NSImage(size: NSSize(width: masterSize, height: masterSize))
masterImage.addRepresentation(masterRep)

/// 缩放到指定尺寸并写 PNG
func writePNG(size: Int, name: String) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    context?.imageInterpolation = .high
    NSGraphicsContext.current = context
    masterImage.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                     from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    try data.write(to: iconsetURL.appendingPathComponent(name))
}

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in variants {
    try writePNG(size: size, name: name)
}
print("iconset: \(iconsetURL.path)")
