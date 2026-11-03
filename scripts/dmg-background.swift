#!/usr/bin/env swift
// Renders the DMG window background: an arrow from the app to the Applications
// alias with a bilingual hint. Writes 1x and 2x PNGs; make-dmg.sh merges them
// into one HiDPI TIFF.
// Usage: swift scripts/dmg-background.swift <output-directory>

import AppKit
import CoreGraphics

// Must match the window and icon positions in make-dmg.sh.
let width: CGFloat = 660
let height: CGFloat = 400
let appIconCenter = CGPoint(x: 165, y: 180)
let applicationsIconCenter = CGPoint(x: 495, y: 180)

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

/// Draws `text` centred on `centerX` with its baseline at `y` (top-left origin).
func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight, color textColor: NSColor, centerX: CGFloat, y: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: textColor,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let bounds = string.size()
    string.draw(at: CGPoint(x: centerX - bounds.width / 2, y: height - y))
}

func render(scale: CGFloat) -> CGImage {
    let context = CGContext(
        data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)

    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xF7F9FC), color(0xE6ECF5)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    // Arrow between the two icons (CoreGraphics has a bottom-left origin).
    let arrowY = height - appIconCenter.y
    let startX = appIconCenter.x + 90
    let endX = applicationsIconCenter.x - 90
    context.setStrokeColor(color(0x3B82E6))
    context.setFillColor(color(0x3B82E6))
    context.setLineWidth(6)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: startX, y: arrowY))
    context.addLine(to: CGPoint(x: endX - 18, y: arrowY))
    context.strokePath()
    context.move(to: CGPoint(x: endX, y: arrowY))
    context.addLine(to: CGPoint(x: endX - 26, y: arrowY + 16))
    context.addLine(to: CGPoint(x: endX - 26, y: arrowY - 16))
    context.closePath()
    context.fillPath()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let primary = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.24, alpha: 1)
    let secondary = NSColor(srgbRed: 0.35, green: 0.40, blue: 0.48, alpha: 1)
    drawText("Kéo NTFS for Mac vào Applications để cài đặt", size: 16, weight: .semibold, color: primary, centerX: width / 2, y: 320)
    drawText("Drag NTFS for Mac to Applications to install", size: 13, weight: .regular, color: secondary, centerX: width / 2, y: 345)
    NSGraphicsContext.restoreGraphicsState()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try writePNG(render(scale: 1), to: outputDirectory.appendingPathComponent("background.png"))
try writePNG(render(scale: 2), to: outputDirectory.appendingPathComponent("background@2x.png"))
