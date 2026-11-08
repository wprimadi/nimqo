// Builds the app icon from the logo on the macOS icon grid:
// swift scripts/make-icon.swift Logo/nimqo.png icon_1024.png, then
// sips each size into app/NIMQO/Assets.xcassets/AppIcon.appiconset.
import AppKit

// macOS icon grid: 1024 canvas, 824 squircle plate centred (100 margin),
// shadow below it; the logo sits inside the plate.
let args = CommandLine.arguments
let logo = NSImage(contentsOfFile: args[1])!
let out = URL(fileURLWithPath: args[2])
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
// Shadow under the plate.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()
// Plate: deep teal-black, lighter at the top, a soft green glow behind the logo.
NSGraphicsContext.saveGraphicsState()
path.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.07, green: 0.16, blue: 0.19, alpha: 1),
                    NSColor(srgbRed: 0.01, green: 0.04, blue: 0.06, alpha: 1)])!
    .draw(in: plate, angle: -90)
NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.75, blue: 0.45, alpha: 0.22),
                    NSColor(srgbRed: 0.20, green: 0.75, blue: 0.45, alpha: 0)])!
    .draw(in: path, relativeCenterPosition: NSPoint(x: 0, y: 0.05))
// A hairline highlight along the top edge: light catching the plate.
NSColor.white.withAlphaComponent(0.10).setStroke()
let rim = NSBezierPath(roundedRect: plate.insetBy(dx: 1.5, dy: 1.5), xRadius: 183.5, yRadius: 183.5)
rim.lineWidth = 3
rim.stroke()
let inset = 72.0
logo.draw(in: plate.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()
do {
    try rep.representation(using: .png, properties: [:])?.write(to: out)
} catch {
    print("cannot write \(out.path): \(error)")
    exit(1)
}
