#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Renders the Nevertype app icon: a deep-teal squircle with a bold, round-capped "N" (cream uprights, coral diagonal).
//
// The mark is plain geometry (no SF Symbols, no font, nothing from another project's artwork). Its proportions are the ones in
// Sources/TypeZero/UI/NevertypeMark.swift, which draws the in-app mark and the menu bar icon; keep the two in step.

// MARK: Mark geometry (fractions of the mark's side, y pointing down, as in NevertypeMark.swift)

let strokeFraction: CGFloat = 0.17
let leftX: CGFloat = 0.25
let rightX: CGFloat = 0.75
let markTop: CGFloat = 0.20
let markBottom: CGFloat = 0.80

// MARK: Colours

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let backgroundTop = rgb(0x1F8C96)      // teal
let backgroundBottom = rgb(0x082F38)   // deep ink teal
let creamLight = rgb(0xFFFAF0)
let creamDark = rgb(0xF6E3C6)
let coralLight = rgb(0xFF8F63)
let coralDark = rgb(0xF2492F)

// MARK: Shapes

/// A superellipse (|x|^n + |y|^n = 1) in `rect`: the continuous "squircle" corner of macOS icons.
func squirclePath(in rect: CGRect, exponent n: Double = 5, steps: Int = 360) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * Double.pi
        let c = cos(t)
        let s = sin(t)
        let point = CGPoint(
            x: rect.midX + a * CGFloat(copysign(pow(abs(c), 2 / n), c)),
            y: rect.midY + b * CGFloat(copysign(pow(abs(s), 2 / n), s))
        )
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func renderIcon(pixelSize: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let nsContext = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "generate-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create a bitmap"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    let cg = nsContext.cgContext
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let s = CGFloat(pixelSize)

    func gradient(_ colors: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
    }

    // 1. The card: the standard macOS icon inset (100 of 1024 points) around a squircle.
    let pad = s * 0.0977
    let card = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let squircle = squirclePath(in: card)

    // Soft drop shadow under the card.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.32))
    cg.addPath(squircle)
    cg.setFillColor(backgroundBottom)
    cg.fillPath()
    cg.restoreGState()

    // 2. Everything else is clipped to the card.
    cg.saveGState()
    cg.addPath(squircle)
    cg.clip()

    cg.drawLinearGradient(
        gradient([backgroundTop, backgroundBottom]),
        start: CGPoint(x: card.midX, y: card.maxY),
        end: CGPoint(x: card.midX, y: card.minY),
        options: []
    )
    // A soft bloom of light from the upper left.
    cg.drawRadialGradient(
        gradient([CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)]),
        startCenter: CGPoint(x: card.minX + card.width * 0.28, y: card.maxY - card.height * 0.12),
        startRadius: 0,
        endCenter: CGPoint(x: card.minX + card.width * 0.28, y: card.maxY - card.height * 0.12),
        endRadius: card.width * 0.62,
        options: []
    )

    // 3. The mark.
    let side = card.width * 0.72
    let box = CGRect(x: card.midX - side / 2, y: card.midY - side / 2, width: side, height: side)
    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + side * fx, y: box.minY + side * (1 - fy))
    }
    let lineWidth = side * strokeFraction

    let uprights = CGMutablePath()
    uprights.move(to: point(leftX, markTop))
    uprights.addLine(to: point(leftX, markBottom))
    uprights.move(to: point(rightX, markTop))
    uprights.addLine(to: point(rightX, markBottom))
    let diagonal = CGMutablePath()
    diagonal.move(to: point(leftX, markTop))
    diagonal.addLine(to: point(rightX, markBottom))

    // Shadow first (both shapes in one opaque colour), then the gradient fills on top of it.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.014), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.38))
    cg.setStrokeColor(creamDark)
    cg.setLineWidth(lineWidth)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.addPath(diagonal)
    cg.addPath(uprights)
    cg.strokePath()
    cg.restoreGState()

    func fillStroke(_ path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
        cg.saveGState()
        cg.addPath(path)
        cg.setLineWidth(lineWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.replacePathWithStrokedPath()
        cg.clip()
        // The round caps lie beyond `from` and `to`, so extend the gradient past both ends.
        cg.drawLinearGradient(gradient(colors), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
    }
    // The diagonal first, so the uprights sit over its two ends.
    fillStroke(diagonal, colors: [coralLight, coralDark], from: point(leftX, markTop), to: point(rightX, markBottom))
    fillStroke(uprights, colors: [creamLight, creamDark], from: point(0.5, markTop), to: point(0.5, markBottom))

    cg.restoreGState()

    // 4. A hairline along the card's edge.
    cg.saveGState()
    cg.addPath(squircle)
    cg.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    cg.setLineWidth(max(1, s * 0.004))
    cg.strokePath()
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "generate-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot encode a PNG"])
    }
    try pngData.write(to: url)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: generate-icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}

let iconsetDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let specs: [(name: String, px: Int)] = [
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

for spec in specs {
    try renderIcon(pixelSize: spec.px, to: iconsetDir.appendingPathComponent(spec.name))
}
print("Generated the Nevertype iconset at \(iconsetDir.path)")
