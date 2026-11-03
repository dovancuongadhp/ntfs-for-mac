#!/usr/bin/env swift
// Renders the app icon (a drive with a Windows logo and a two-way arrow) and
// writes every size macOS needs into App/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift

import AppKit
import CoreGraphics

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

func renderIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: s / 1024, y: s / 1024)

    // Background tile, inset like Apple's icon grid.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, alpha: 0.35))
    context.addPath(tilePath)
    context.setFillColor(color(0x1E5BD8))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x3FA0FF), color(0x1747C2)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()

    // Drive body.
    let body = CGRect(x: 210, y: 300, width: 604, height: 300)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, alpha: 0.3))
    context.addPath(CGPath(roundedRect: body, cornerWidth: 56, cornerHeight: 56, transform: nil))
    context.setFillColor(color(0xF4F7FB))
    context.fillPath()
    context.restoreGState()

    // Front panel strip with a status light.
    let strip = CGRect(x: 250, y: 340, width: 524, height: 70)
    context.addPath(CGPath(roundedRect: strip, cornerWidth: 22, cornerHeight: 22, transform: nil))
    context.setFillColor(color(0xD5DDE8))
    context.fillPath()
    context.setFillColor(color(0x34C759))
    context.fillEllipse(in: CGRect(x: 700, y: 357, width: 36, height: 36))

    // Windows logo: four tiles.
    let pane: CGFloat = 60
    let gap: CGFloat = 9
    let logoSize = pane * 2 + gap
    // Centered between the front strip and the top of the drive.
    let logoOrigin = CGPoint(x: 512 - logoSize / 2, y: strip.maxY + (body.maxY - strip.maxY - logoSize) / 2)
    context.setFillColor(color(0x1E6FE8))
    for row in 0..<2 {
        for column in 0..<2 {
            context.fill(CGRect(
                x: logoOrigin.x + CGFloat(column) * (pane + gap),
                y: logoOrigin.y + CGFloat(row) * (pane + gap),
                width: pane, height: pane))
        }
    }

    // Two-way arrow above the drive: read and write.
    context.setStrokeColor(color(0xFFFFFF))
    context.setFillColor(color(0xFFFFFF))
    context.setLineWidth(34)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 330, y: 735))
    context.addLine(to: CGPoint(x: 694, y: 735))
    context.strokePath()
    for (tip, direction) in [(CGPoint(x: 270, y: 735), CGFloat(1)), (CGPoint(x: 754, y: 735), CGFloat(-1))] {
        context.move(to: tip)
        context.addLine(to: CGPoint(x: tip.x + 95 * direction, y: tip.y + 62))
        context.addLine(to: CGPoint(x: tip.x + 95 * direction, y: tip.y - 62))
        context.closePath()
        context.fillPath()
    }

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let sizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scale) in sizes {
    let pixels = points * scale
    let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try writePNG(renderIcon(size: pixels), to: outputDirectory.appendingPathComponent(filename))
    images.append([
        "filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)",
    ])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(outputDirectory.path)")
