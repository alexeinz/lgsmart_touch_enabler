// Renders Resources/AppIcon.icns. Usage: swift scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
    ctx.addPath(path); ctx.clip()

    let cs = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: cs, colors: [
        NSColor(red: 0.05, green: 0.07, blue: 0.20, alpha: 1).cgColor,
        NSColor(red: 0.28, green: 0.12, blue: 0.55, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // glow under the touch point
    let c = CGPoint(x: s * 0.5, y: s * 0.46)
    let glow = CGGradient(colorsSpace: cs, colors: [
        NSColor(red: 0.2, green: 0.9, blue: 1, alpha: 0.55).cgColor,
        NSColor(red: 0.2, green: 0.9, blue: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.42, options: [])

    // ripples
    for (i, r) in [0.14, 0.24, 0.34].enumerated() {
        ctx.setStrokeColor(NSColor(red: 0.45, green: 0.95, blue: 1, alpha: 0.9 - Double(i) * 0.25).cgColor)
        ctx.setLineWidth(s * 0.028)
        ctx.strokeEllipse(in: CGRect(x: c.x - s * r, y: c.y - s * r, width: s * r * 2, height: s * r * 2))
    }
    // fingertip
    ctx.setFillColor(NSColor.white.cgColor)
    let d = s * 0.1
    ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))

    // monitor bezel line at the bottom
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
    ctx.setLineWidth(s * 0.02); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: s * 0.3, y: s * 0.17)); ctx.addLine(to: CGPoint(x: s * 0.7, y: s * 0.17)); ctx.strokePath()
    img.unlockFocus()

    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = "build/AppIcon.iconset"
try? fm.removeItem(atPath: set)
try fm.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
