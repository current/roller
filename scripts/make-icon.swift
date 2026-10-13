// Draws the app icon and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // Squircle-ish background with the macOS icon grid margin.
    let bg = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: bg, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.15, blue: 0.22, alpha: 1),
               ending: NSColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 1))!.draw(in: path, angle: -90)
    // The strip: columns running past the edges, one focused.
    path.addClip()
    let widths: [CGFloat] = [170, 250, 300, 220, 200]
    var x: CGFloat = 20
    for (i, w) in widths.enumerated() {
        let r = NSRect(x: x * s, y: 270 * s, width: (w - 26) * s, height: 484 * s)
        let col = NSBezierPath(roundedRect: r, xRadius: 34 * s, yRadius: 34 * s)
        if i == 2 {
            NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.62, blue: 1.0, alpha: 1),
                       ending: NSColor(srgbRed: 0.20, green: 0.42, blue: 0.98, alpha: 1))!.draw(in: col, angle: -90)
        } else {
            NSColor(white: 1, alpha: i == 1 || i == 3 ? 0.30 : 0.14).setFill()
            col.fill()
        }
        x += w
    }
    // The screen frame around the middle.
    let screen = NSBezierPath(roundedRect: NSRect(x: 168 * s, y: 236 * s, width: 688 * s, height: 552 * s), xRadius: 48 * s, yRadius: 48 * s)
    screen.lineWidth = 22 * s
    NSColor.white.withAlphaComponent(0.92).setStroke()
    screen.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
