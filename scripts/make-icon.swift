#!/usr/bin/env swift
import AppKit
import Foundation

// Render an `.iconset` directory of PNGs at the sizes macOS expects, then
// iconutil(1) (called separately) collapses it into a single `.icns`.
let sizes: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

func drawIcon(pixelSize: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    let cornerRadius = CGFloat(pixelSize) * 0.2237

    let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    backgroundPath.addClip()

    let topColor = NSColor(red: 0.32, green: 0.40, blue: 0.96, alpha: 1.0)
    let bottomColor = NSColor(red: 0.58, green: 0.22, blue: 0.86, alpha: 1.0)
    let gradient = NSGradient(starting: topColor, ending: bottomColor)!
    gradient.draw(in: rect, angle: 270)

    // Subtle inner highlight for depth.
    let highlight = NSColor.white.withAlphaComponent(0.18)
    highlight.setFill()
    let highlightHeight = CGFloat(pixelSize) * 0.38
    let highlightRect = NSRect(x: 0, y: CGFloat(pixelSize) - highlightHeight, width: CGFloat(pixelSize), height: highlightHeight)
    let highlightGradient = NSGradient(starting: highlight, ending: NSColor.clear)!
    highlightGradient.draw(in: highlightRect, angle: 270)

    // Draw the studio mic emoji as the visual mark.
    let emoji = "🎙️"
    let fontSize = CGFloat(pixelSize) * 0.55
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize)
    ]
    let str = NSAttributedString(string: emoji, attributes: attrs)
    let strSize = str.size()
    str.draw(at: NSPoint(
        x: (CGFloat(pixelSize) - strSize.width) / 2,
        y: (CGFloat(pixelSize) - strSize.height) / 2 - CGFloat(pixelSize) * 0.04
    ))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetDir = cwd.appendingPathComponent("build/AppIcon.iconset")

try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for (size, scale) in sizes {
    let pixelSize = size * scale
    let rep = drawIcon(pixelSize: pixelSize)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("ERROR: PNG encode failed at \(pixelSize)\n".utf8))
        exit(1)
    }
    let filename = scale == 1
        ? "icon_\(size)x\(size).png"
        : "icon_\(size)x\(size)@2x.png"
    let url = iconsetDir.appendingPathComponent(filename)
    try png.write(to: url)
    print("  Wrote \(filename) (\(pixelSize)x\(pixelSize))")
}

print("Iconset ready at \(iconsetDir.path)")
