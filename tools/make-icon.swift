// Renders Resources/AppIcon.icns (Finder / Spotlight icon). Run: swift tools/make-icon.swift
import Cocoa

let dir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 18
    let bg = NSRect(x: 0, y: 0, width: px, height: px).insetBy(dx: s * 1.4, dy: s * 1.4)
    NSColor(white: 0.1, alpha: 1).setFill()
    NSBezierPath(roundedRect: bg, xRadius: s * 3.5, yRadius: s * 3.5).fill()
    NSColor.systemGreen.setStroke()
    let w = s * 0.9
    let ring = NSBezierPath(ovalIn: bg.insetBy(dx: s * 2, dy: s * 2))
    ring.lineWidth = w
    ring.stroke()
    let bolt = NSBezierPath()
    let pts: [(CGFloat, CGFloat)] = [(10, 13), (6.5, 8.5), (9, 8.5), (8, 5), (11.5, 9.5), (9, 9.5)]
    bolt.move(to: NSPoint(x: pts[0].0 * s, y: pts[0].1 * s))
    for (x, y) in pts.dropFirst() { bolt.line(to: NSPoint(x: x * s, y: y * s)) }
    bolt.close()
    bolt.lineWidth = w
    bolt.lineJoinStyle = .round
    bolt.stroke()
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}

// GitHub mark for the menu (from @primer/octicons mark-github-16.svg, saved to build/github.svg)
if let svg = NSImage(contentsOfFile: "build/github.svg") {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    svg.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/github.png"))
}
