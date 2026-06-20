#!/usr/bin/env swift
// Renders the Introspect app icon master PNG (1024x1024).
// Abstract mark: two concentric arcs spiralling inward to a focal dot —
// "introspection": reflection turning inward, signals distilled to a point.
// Usage: swiftc -O render-app-icon.swift && ./render-app-icon <output.png>

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let canvas: CGFloat = 1024
let cx: CGFloat = 512, cy: CGFloat = 512

func hex(_ h: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255,
            green: CGFloat((h >> 8) & 0xFF) / 255,
            blue: CGFloat(h & 0xFF) / 255, alpha: a)
}

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("Could not create bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: squircle ~824pt centered on a 1024 canvas, corner radius ~185.
let inset: CGFloat = 100
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset),
    xRadius: 185, yRadius: 185
)

// Background: the app's indigo accent (#5E6AD2) as a vertical gradient, lighter at the top.
NSGradient(starting: hex(0x7C86E8), ending: hex(0x434FB0))?.draw(in: squircle, angle: -90)

// Glassy top inner highlight so the surface reads as glass, not flat paint.
squircle.addClip()
NSGradient(
    starting: NSColor.white.withAlphaComponent(0.16),
    ending: NSColor.white.withAlphaComponent(0.0)
)?.draw(in: NSRect(x: inset, y: canvas - inset - 300, width: canvas - 2 * inset, height: 300), angle: -90)

// Mark drawn into its own layer so it casts a single clean shadow.
let mark = NSImage(size: NSSize(width: canvas, height: canvas))
mark.lockFocus()

func arc(radius r: CGFloat, width lw: CGFloat, gapCenter: CGFloat, gapHalf: CGFloat, color: NSColor) {
    let p = NSBezierPath()
    p.lineWidth = lw
    p.lineCapStyle = .round
    p.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r,
                startAngle: gapCenter + gapHalf,
                endAngle: gapCenter - gapHalf + 360,
                clockwise: false)
    color.setStroke()
    p.stroke()
}

// Two broken rings with offset gaps create an inward spiral; the inner ring is
// brighter so the eye is pulled toward the focal dot at the centre.
arc(radius: 244, width: 60, gapCenter: 72, gapHalf: 40, color: hex(0xEEF0FF, 0.58))
arc(radius: 142, width: 60, gapCenter: 132, gapHalf: 50, color: hex(0xEEF0FF, 0.90))
hex(0xFFFFFF).setFill()
NSBezierPath(ovalIn: NSRect(x: cx - 48, y: cy - 48, width: 96, height: 96)).fill()

mark.unlockFocus()

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
shadow.shadowBlurRadius = 22
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
mark.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), from: .zero, operation: .sourceOver, fraction: 1.0)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
