// Regenerates Resources/AppIcon.icns:  swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's icon grid: an 824 pt body centered on a 1024 pt canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(srgbRed: 0.12, green: 0.10, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 0.29, green: 0.25, blue: 0.85, alpha: 1),
    ])?.draw(in: shape, angle: 90)

    // A heartbeat line, drawn by hand: SF Symbols may not be used in app icons.
    let pulse = NSBezierPath()
    pulse.move(to: NSPoint(x: 220, y: 560))
    for point in [(372, 560), (432, 470), (512, 768), (592, 372), (652, 612), (692, 560), (804, 560)] {
        pulse.line(to: NSPoint(x: point.0, y: point.1))
    }
    pulse.lineWidth = 58
    pulse.lineCapStyle = .round
    pulse.lineJoinStyle = .round
    NSColor.white.setStroke()
    pulse.stroke()

    // Three status dots: needs you, running, finished.
    let colors: [NSColor] = [.systemOrange, .systemBlue, .systemGreen]
    for (index, color) in colors.enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 392 + CGFloat(index) * 90, y: 230, width: 60, height: 60)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try drawIcon(pixels: points * scale)?.write(to: iconset.appending(path: name))
    }
}
print(iconset.path)
