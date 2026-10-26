// round-icon.swift：把方形源图（AppIcon-source.png）做成 macOS 风格圆角图标 AppIcon.png。
// 用法：swift packaging/round-icon.swift packaging/AppIcon-source.png packaging/AppIcon.png
// 规格：1024 画布，图标主体 824×824 居中，圆角半径 185，带柔和投影（对齐 macOS 图标网格）。
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    print("用法：swift round-icon.swift <源图.png> <输出.png>"); exit(1)
}
let S = 1024, body = 824, radius: CGFloat = 185
let off = CGFloat(S - body) / 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: S, height: S)
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let rect = NSRect(x: off, y: off, width: CGFloat(body), height: CGFloat(body))
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
// 投影
ctx.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.white.setFill()
path.fill()
ctx.restoreGraphicsState()
// 圆角裁剪后画源图
ctx.saveGraphicsState()
path.addClip()
src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
ctx.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("已生成 \(args[2])")
