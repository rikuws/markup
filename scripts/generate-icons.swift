#!/usr/bin/env swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourceDirectory = root.appendingPathComponent("Sources/Markup/Resources", isDirectory: true)
let workDirectory = root.appendingPathComponent(".build/icon-work", isDirectory: true)
let iconsetDirectory = workDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)

try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)

func makeBitmap(size: Int, draw: (NSRect) -> Void) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not allocate \(size)x\(size) icon bitmap.")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    draw(NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(url.path).")
    }
    try data.write(to: url, options: .atomic)
}

func strokeViewfinder(
    in rect: NSRect,
    centerRadius: CGFloat,
    cornerLength: CGFloat,
    lineWidth: CGFloat,
    color: NSColor
) {
    let path = NSBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round

    path.move(to: NSPoint(x: rect.minX, y: rect.maxY - cornerLength))
    path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
    path.line(to: NSPoint(x: rect.minX + cornerLength, y: rect.maxY))

    path.move(to: NSPoint(x: rect.maxX - cornerLength, y: rect.maxY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - cornerLength))

    path.move(to: NSPoint(x: rect.maxX, y: rect.minY + cornerLength))
    path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX - cornerLength, y: rect.minY))

    path.move(to: NSPoint(x: rect.minX + cornerLength, y: rect.minY))
    path.line(to: NSPoint(x: rect.minX, y: rect.minY))
    path.line(to: NSPoint(x: rect.minX, y: rect.minY + cornerLength))

    color.setStroke()
    path.lineWidth = lineWidth
    path.stroke()

    let circleRect = NSRect(
        x: rect.midX - centerRadius,
        y: rect.midY - centerRadius,
        width: centerRadius * 2,
        height: centerRadius * 2
    )
    let circle = NSBezierPath(ovalIn: circleRect)
    circle.lineWidth = lineWidth * 0.92
    circle.stroke()
}

func drawAppIcon(in bounds: NSRect) {
    let size = min(bounds.width, bounds.height)
    let iconRect = bounds.insetBy(dx: size * 0.115, dy: size * 0.115)
    let radius = size * 0.185
    let shape = NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
    shadow.shadowBlurRadius = size * 0.050
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.025)
    shadow.set()
    NSColor.black.withAlphaComponent(0.72).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.190, green: 0.198, blue: 0.214, alpha: 1.0),
        NSColor(calibratedRed: 0.072, green: 0.076, blue: 0.084, alpha: 1.0)
    ])?.draw(in: shape, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSColor.white.withAlphaComponent(0.040).setFill()
    NSRect(
        x: iconRect.minX,
        y: iconRect.midY,
        width: iconRect.width,
        height: iconRect.height / 2
    ).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.085).setStroke()
    shape.lineWidth = max(1, size * 0.006)
    shape.stroke()

    let glyphRect = iconRect.insetBy(dx: iconRect.width * 0.185, dy: iconRect.height * 0.185)
    strokeViewfinder(
        in: glyphRect,
        centerRadius: size * 0.098,
        cornerLength: glyphRect.width * 0.250,
        lineWidth: max(4, size * 0.034),
        color: NSColor.white.withAlphaComponent(0.96)
    )
}

func drawMenuIcon(in bounds: NSRect) {
    let glyphRect = bounds.insetBy(dx: bounds.width * 0.135, dy: bounds.height * 0.135)
    strokeViewfinder(
        in: glyphRect,
        centerRadius: bounds.width * 0.145,
        cornerLength: glyphRect.width * 0.265,
        lineWidth: max(4, bounds.width * 0.095),
        color: NSColor.black
    )
}

let appIconSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in appIconSizes {
    try writePNG(
        makeBitmap(size: size, draw: drawAppIcon),
        to: iconsetDirectory.appendingPathComponent(name)
    )
}

try writePNG(makeBitmap(size: 88, draw: drawMenuIcon), to: resourceDirectory.appendingPathComponent("MenuBarIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c",
    "icns",
    "-o",
    resourceDirectory.appendingPathComponent("AppIcon.icns").path,
    iconsetDirectory.path
]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus).")
}

print("Generated Markup icons.")
