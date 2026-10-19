import AppKit
import PulseCore

/// The README's menu-bar picture: the top-right corner of a desktop, with the Copilot Pulse item pressed and its
/// panel open below in a popover. AppKit draws the status buttons; the wallpaper, bar, highlight and popover use
/// plain colors, since offscreen rendering doesn't capture materials.
@MainActor
enum MenuBarPicture {
    /// In points, and the README's width for the picture: narrow enough to sit next to the widget picture in
    /// GitHub's README column.
    private static let width: CGFloat = 440
    private static let barHeight: CGFloat = 24
    /// Between status buttons, on top of their own padding.
    private static let itemGap: CGFloat = 4
    private static let trailingInset: CGFloat = 6
    /// Room around the popover for its shadow.
    private static let margin: CGFloat = 20
    private static let arrow = NSSize(width: 30, height: 12)
    private static let cornerRadius: CGFloat = 12

    static func draw(panel: NSBitmapImageRep, counts: PhaseCounts, appearance: NSAppearance) -> NSBitmapImageRep? {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // Right-aligned like the system's items: Copilot Pulse, battery, Wi-Fi, Control Center and the clock.
        let pulse = NSStatusBarButton(frame: .zero)
        StatusItemController.configure(pulse, for: counts)
        let items = [pulse, symbolButton("battery.75percent"), symbolButton("wifi"), symbolButton("switch.2"), clockButton()]
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: barHeight))
        var x = width - trailingInset
        for item in items.reversed() {
            let itemWidth = ceil(item.fittingSize.width)
            x -= itemWidth
            item.frame = NSRect(x: x, y: 0, width: itemWidth, height: barHeight)
            bar.addSubview(item)
            x -= itemGap
        }
        guard let barImage = Renderer.snapshot(bar, appearance: appearance) else { return nil }

        let height = barHeight + 1 + arrow.height + panel.size.height + margin * 1.5
        let size = NSSize(width: width, height: height)
        let scale = CGFloat(panel.pixelsWide) / panel.size.width
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: Int((width * scale).rounded()), height: Int((height * scale).rounded()),
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)

        let barRect = NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
        // The arrow points at the item's center; the body stays as centered under it as the picture's edges allow.
        let anchor = pulse.frame.midX
        let bodyX = min(max(anchor - panel.size.width / 2, margin), width - margin - panel.size.width)
        let body = NSRect(origin: NSPoint(x: bodyX, y: barRect.minY - 1 - arrow.height - panel.size.height),
                          size: panel.size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        appearance.performAsCurrentDrawingAppearance {
            drawWallpaper(in: NSRect(origin: .zero, size: size), dark: dark)
            (dark ? NSColor(white: 0.1, alpha: 0.4) : NSColor(white: 1, alpha: 0.5)).setFill()
            barRect.fill(using: .sourceOver)
            // Pressed, since its popover is open.
            (dark ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.1)).setFill()
            NSBezierPath(roundedRect: pulse.frame.offsetBy(dx: 0, dy: barRect.minY).insetBy(dx: 0, dy: 1),
                         xRadius: 5, yRadius: 5).fill()
            barImage.draw(in: barRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawPopover(panel: panel, body: body, anchor: anchor, dark: dark, scale: scale)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        return rep
    }

    private static func symbolButton(_ name: String) -> NSStatusBarButton {
        let button = NSStatusBarButton(frame: .zero)
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        return button
    }

    private static func clockButton() -> NSStatusBarButton {
        let button = NSStatusBarButton(frame: .zero)
        button.font = NSFont.menuBarFont(ofSize: 0)
        button.title = "Mon Oct 19  9:41 AM"
        return button
    }

    private static func drawWallpaper(in rect: NSRect, dark: Bool) {
        let colors = dark
            ? [NSColor(srgbRed: 0.10, green: 0.14, blue: 0.32, alpha: 1),
               NSColor(srgbRed: 0.24, green: 0.15, blue: 0.40, alpha: 1),
               NSColor(srgbRed: 0.38, green: 0.16, blue: 0.34, alpha: 1)]
            : [NSColor(srgbRed: 0.62, green: 0.76, blue: 0.98, alpha: 1),
               NSColor(srgbRed: 0.78, green: 0.72, blue: 0.96, alpha: 1),
               NSColor(srgbRed: 0.97, green: 0.78, blue: 0.86, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: rect, angle: -60)
    }

    private static func drawPopover(panel: NSBitmapImageRep, body: NSRect, anchor: CGFloat, dark: Bool, scale: CGFloat) {
        let outline = popoverOutline(body: body, anchor: anchor)

        NSGraphicsContext.saveGraphicsState()
        // Core Graphics measures shadows in pixels, unaffected by the context's scale.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
        shadow.shadowBlurRadius = 22 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        panel.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        if dark {
            hairline(outline, color: NSColor.black.withAlphaComponent(0.6), inside: false)
            hairline(outline, color: NSColor.white.withAlphaComponent(0.16), inside: true)
        } else {
            hairline(outline, color: NSColor.black.withAlphaComponent(0.16), inside: false)
        }
    }

    /// The body's rounded rectangle with an arrow on top whose tip is above `anchor`.
    private static func popoverOutline(body: NSRect, anchor: CGFloat) -> NSBezierPath {
        let top = body.maxY
        let half = arrow.width / 2
        let tip = NSPoint(x: anchor, y: top + arrow.height)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: anchor - half, y: top))
        path.curve(to: tip, controlPoint1: NSPoint(x: anchor - half * 0.5, y: top),
                   controlPoint2: NSPoint(x: anchor - half * 0.2, y: tip.y))
        path.curve(to: NSPoint(x: anchor + half, y: top), controlPoint1: NSPoint(x: anchor + half * 0.2, y: tip.y),
                   controlPoint2: NSPoint(x: anchor + half * 0.5, y: top))
        path.appendArc(from: NSPoint(x: body.maxX, y: top), to: NSPoint(x: body.maxX, y: body.minY), radius: cornerRadius)
        path.appendArc(from: NSPoint(x: body.maxX, y: body.minY), to: NSPoint(x: body.minX, y: body.minY), radius: cornerRadius)
        path.appendArc(from: NSPoint(x: body.minX, y: body.minY), to: NSPoint(x: body.minX, y: top), radius: cornerRadius)
        path.appendArc(from: NSPoint(x: body.minX, y: top), to: NSPoint(x: anchor - half, y: top), radius: cornerRadius)
        path.close()
        return path
    }

    /// A one-pixel line (at @2x) just inside or just outside the outline.
    private static func hairline(_ outline: NSBezierPath, color: NSColor, inside: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath()
        if !inside {
            clip.append(NSBezierPath(rect: outline.bounds.insetBy(dx: -10, dy: -10)))
            clip.windingRule = .evenOdd
        }
        clip.append(outline)
        clip.addClip()
        color.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
