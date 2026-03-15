#!/usr/bin/env swift
// Generates Command.icns — a ⌘. icon on a dark rounded rect

import AppKit

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext

    // Background: dark rounded rect with gradient
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Gradient: dark charcoal to near-black
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0),
            CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        ] as CFArray,
        locations: [0, 1]
    )!

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // Subtle inner border
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.setLineWidth(size * 0.01)
    ctx.strokePath()
    ctx.restoreGState()

    // Draw "⌘." text
    let fontSize = size * 0.38
    let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
    let text = "⌘."
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 1.0)
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let textSize = attrStr.size()
    let textOrigin = NSPoint(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2
    )
    attrStr.draw(at: textOrigin)

    image.unlockFocus()
    return image
}

func pngData(for image: NSImage) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(image.size.width),
        pixelsHigh: Int(image.size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Generate icon set
let iconsetPath = "/tmp/Command.iconset"
try? FileManager.default.removeItem(atPath: iconsetPath)
try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let image = renderIcon(size: px)
    let data = pngData(for: image)
    try data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name).png"))
}

// Convert to .icns
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetPath, "-o", outputPath]
try task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("Generated \(outputPath)")
} else {
    print("iconutil failed with status \(task.terminationStatus)")
}
