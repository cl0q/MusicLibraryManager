#!/usr/bin/env swift
// Renders the library-file icon (ICON-MLIBM variant A "record crate", DEC-033) into
// MLM/Resources/LibraryFile.icns.
//
// The drawing is the SVG of design/b1/library-icon.html (variant A), transcribed shape by
// shape: the full drawing (viewBox 0 0 256 256) for 128 pt and up, the redrawn small ones
// (viewBox 0 0 32 32) for 32 pt and 16 pt, as that page specifies ("small sizes are redrawn,
// not scaled"). Colours are the page's fixed mixes of white and black; the one tint is the
// page's accent (system blue) standing in for the app icon's colour.
//
// Usage (from the repository root, built-in tools only):
//   swift scripts/render-library-icon.swift            # writes MLM/Resources/LibraryFile.icns
//   swift scripts/render-library-icon.swift <out.icns>
import AppKit
import Foundation

// MARK: - Colours (library-icon.html `.icn` custom properties)

func gray(_ white: CGFloat) -> CGColor { CGColor(gray: white, alpha: 1) }
let ic1 = gray(0.98)   // color-mix(white 98%, black)
let ic2 = gray(0.89)
let ic3 = gray(0.77)
let ic4 = gray(0.60)
let ic5 = gray(0.30)
let icLine = CGColor(gray: 0, alpha: 0.26)          // color-mix(black 26%, transparent)
let accent = CGColor(srgbRed: 0, green: 122.0 / 255, blue: 1, alpha: 1)   // --accent #007aff

// MARK: - Primitives (SVG coordinates: origin top left, y down)

struct Canvas {
    let context: CGContext
    let strokeWidth: CGFloat

    /// `<rect … rx>` with an optional `rotate(angle cx cy)`; `stroked` = `stroke: var(--ic-line)`.
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, rx: CGFloat, fill: CGColor,
              stroked: Bool = true, rotate: (angle: CGFloat, cx: CGFloat, cy: CGFloat)? = nil) {
        context.saveGState()
        if let rotate {
            context.translateBy(x: rotate.cx, y: rotate.cy)
            context.rotate(by: rotate.angle * .pi / 180)
            context.translateBy(x: -rotate.cx, y: -rotate.cy)
        }
        let path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                          cornerWidth: rx, cornerHeight: rx, transform: nil)
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        if stroked {
            context.addPath(path)
            context.setStrokeColor(icLine)
            context.setLineWidth(strokeWidth)
            context.strokePath()
        }
        context.restoreGState()
    }

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, fill: CGColor) {
        context.setFillColor(fill)
        context.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    }

    func ring(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, color: CGColor, width: CGFloat, opacity: CGFloat) {
        context.saveGState()
        context.setAlpha(opacity)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        context.restoreGState()
    }

    func line(from: CGPoint, to: CGPoint) {
        context.setStrokeColor(icLine)
        context.setLineWidth(strokeWidth)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
    }

    /// `disc(cx, cy, r, big)`: the placeholder mark — a record with a tinted label.
    func disc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, big: Bool) {
        circle(cx, cy, r, fill: ic5)
        if big {
            ring(cx, cy, r * 0.76, color: ic4, width: 1.5, opacity: 0.55)
            ring(cx, cy, r * 0.56, color: ic4, width: 1.5, opacity: 0.55)
        }
        circle(cx, cy, r * (big ? 0.36 : 0.4), fill: accent)
        if big { circle(cx, cy, r * 0.07, fill: ic1) }
    }
}

// MARK: - Variant A

/// `FULL.A`, viewBox 0 0 256 256.
func drawFull(_ c: Canvas) {
    c.rect(52, 30, 152, 150, rx: 9, fill: ic4, rotate: (-9, 128, 190))
    c.rect(52, 34, 152, 150, rx: 9, fill: ic3, rotate: (-3, 128, 190))
    c.rect(52, 40, 152, 150, rx: 9, fill: ic2, rotate: (5, 128, 190))
    c.rect(50, 54, 156, 156, rx: 10, fill: ic1)
    c.disc(128, 108, 42, big: true)
    c.rect(30, 156, 196, 80, rx: 13, fill: ic3)
    c.line(from: CGPoint(x: 31, y: 196), to: CGPoint(x: 225, y: 196))
    c.rect(98, 170, 60, 16, rx: 8, fill: ic5)
}

/// `SMALL(s16).A`, viewBox 0 0 32 32 — redrawn for 32 pt (`s16 == false`) and 16 pt.
func drawSmall(_ c: Canvas, s16: Bool) {
    if !s16 { c.rect(9, 2.5, 14, 6, rx: 1.5, fill: ic4) }
    c.rect(7.5, s16 ? 3.5 : 5, 17, 6, rx: 1.5, fill: ic3)
    c.rect(6, 7.5, 20, 15, rx: 2, fill: ic1)
    c.disc(16, 13.5, s16 ? 4.2 : 4.6, big: false)
    c.rect(2.5, 18.5, 27, 11, rx: 2.5, fill: ic3)
    c.rect(11.5, 22, 9, s16 ? 3.6 : 3, rx: 1.5, fill: ic5, stroked: false)
}

// MARK: - Rendering

func render(points: Int, scale: Int) throws -> Data {
    let pixels = points * scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else { throw NSError(domain: "render-library-icon", code: 1) }
    let context = graphics.cgContext
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    let viewBox: CGFloat = points <= 32 ? 32 : 256
    // SVG space: y down, viewBox scaled to the bitmap.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: CGFloat(pixels) / viewBox, y: -CGFloat(pixels) / viewBox)
    if points <= 32 {
        drawSmall(Canvas(context: context, strokeWidth: points <= 16 ? 1.6 : 1), s16: points <= 16)
    } else {
        drawFull(Canvas(context: context, strokeWidth: 2))
    }
    context.flush()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render-library-icon", code: 2)
    }
    return png
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("MLM/Resources/LibraryFile.icns")
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("LibraryFile-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(points: points, scale: scale).write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (\(iconutil.terminationStatus))\n".utf8))
    exit(1)
}
print("wrote \(output.path)")
