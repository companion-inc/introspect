#!/usr/bin/env swift
// Renders the Introspect app icon master PNG (1024x1024).
// Usage: swift scripts/render-app-icon.swift <output.png>

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let canvas: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas),
    pixelsHigh: Int(canvas),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Could not create bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: squircle ~824pt centered on a 1024 canvas, corner radius ~185.
let inset: CGFloat = 100
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset),
    xRadius: 185,
    yRadius: 185
)

// Background: the app's teal accent as a vertical gradient, light at the top.
let topColor = NSColor(calibratedRed: 0.30, green: 0.64, blue: 0.76, alpha: 1)
let bottomColor = NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.40, alpha: 1)
NSGradient(starting: topColor, ending: bottomColor)?.draw(in: squircle, angle: -90)

// Subtle top inner highlight so the surface reads as glass, not flat paint.
squircle.addClip()
let highlight = NSGradient(
    starting: NSColor.white.withAlphaComponent(0.18),
    ending: NSColor.white.withAlphaComponent(0.0)
)
highlight?.draw(
    in: NSRect(x: inset, y: canvas - inset - 260, width: canvas - 2 * inset, height: 260),
    angle: -90
)

// Glyph: a simple brain mark in white.
let symbolConfig = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
guard let symbol = NSImage(
    systemSymbolName: "brain",
    accessibilityDescription: nil
)?.withSymbolConfiguration(symbolConfig) else {
    fatalError("Could not load SF Symbol")
}

let tinted = NSImage(size: symbol.size)
tinted.lockFocus()
symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
NSColor.white.set()
NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
tinted.unlockFocus()

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()

let glyphHeight: CGFloat = 470
let glyphWidth = glyphHeight * tinted.size.width / tinted.size.height
tinted.draw(
    in: NSRect(
        x: (canvas - glyphWidth) / 2,
        y: (canvas - glyphHeight) / 2,
        width: glyphWidth,
        height: glyphHeight
    ),
    from: .zero,
    operation: .sourceOver,
    fraction: 1.0
)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
