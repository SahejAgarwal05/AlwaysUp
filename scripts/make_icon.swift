#!/usr/bin/env swift
// Renders the AlwaysUp app icon into an .iconset folder.
// Usage: swift scripts/make_icon.swift <outdir.iconset>
//
// Pure CoreGraphics vector drawing; every size is rendered directly.
// Mark (unit square, y up): lid bar (0.20,0.24)-(0.80,0.24);
// chevron (0.25,0.47)-(0.50,0.72)-(0.75,0.47). Round caps/joins.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make_icon.swift <outdir>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Geometry (1024 design space)

let canvas: CGFloat = 1024
let bodySize: CGFloat = 824
let bodyOrigin = (canvas - bodySize) / 2          // 100
let cornerRadius: CGFloat = 185

/// Continuous-corner ("squircle") rounded rect. Each corner is a
/// superellipse quadrant spanning `k * radius` along each edge, so the
/// curvature ramps in smoothly from the straight edges (like Apple's
/// continuous corners) while bulging about as far as a circular arc of
/// `radius` would at the 45-degree point.
func continuousRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let k: CGFloat = 1.4
    let n: CGFloat = 3.27
    let e = min(radius * k, min(r.width, r.height) / 2)
    let steps = 96
    let p = CGMutablePath()
    // (vertex x, vertex y, inward dx, inward dy, reverse) per corner, CCW from bottom-right.
    func corner(_ vx: CGFloat, _ vy: CGFloat, _ dx: CGFloat, _ dy: CGFloat, _ startOnHorizontal: Bool) {
        let ccx = vx + dx * e, ccy = vy + dy * e
        for i in 0...steps {
            var t = CGFloat(i) / CGFloat(steps) * (.pi / 2)
            if startOnHorizontal { t = .pi / 2 - t }
            let x = pow(cos(t), 2 / n), y = pow(sin(t), 2 / n)
            p.addLine(to: CGPoint(x: ccx - dx * e * x, y: ccy - dy * e * y))
        }
    }
    p.move(to: CGPoint(x: r.minX + e, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY))
    corner(r.maxX, r.minY, -1, 1, true)
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - e))
    corner(r.maxX, r.maxY, -1, -1, false)
    p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY))
    corner(r.minX, r.maxY, 1, -1, true)
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + e))
    corner(r.minX, r.minY, 1, 1, false)
    p.closeSubpath()
    return p
}

// MARK: - Rendering

func render(pixels: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)

    let small = pixels <= 32
    let tiny = pixels <= 16

    let bodyRect = CGRect(x: bodyOrigin, y: bodyOrigin, width: bodySize, height: bodySize)
    let body = continuousRect(bodyRect, radius: cornerRadius)

    // Drop shadow beneath body (softer / skipped at tiny sizes).
    if !tiny {
        ctx.saveGState()
        // setShadow works in device pixels, so scale it with the canvas.
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                      color: CGColor(gray: 0, alpha: small ? 0.25 : 0.35))
        ctx.addPath(body)
        ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Body fill: subtle vertical gradient #1C1C1C (top) -> #0A0A0A (bottom).
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0x1C/255, green: 0x1C/255, blue: 0x1C/255, alpha: 1),
        CGColor(srgbRed: 0x0A/255, green: 0x0A/255, blue: 0x0A/255, alpha: 1)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: bodyRect.maxY),
                           end: CGPoint(x: 0, y: bodyRect.minY), options: [])
    ctx.restoreGState()

    // Inner hairline highlight (top-lit), only where it can resolve.
    if !small {
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let hw: CGFloat = max(1.0 / scale, 2.0)   // ~2px at 1024, >=1 device px
        ctx.addPath(body)
        ctx.setLineWidth(hw * 2)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let edge = CGGradient(colorsSpace: cs, colors: [
            CGColor(gray: 1, alpha: 0.16),
            CGColor(gray: 1, alpha: 0.04),
            CGColor(gray: 1, alpha: 0.02)
        ] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(edge, start: CGPoint(x: 0, y: bodyRect.maxY),
                               end: CGPoint(x: 0, y: bodyRect.minY), options: [])
        ctx.restoreGState()
    }

    // Mark. Visible width (bar incl. caps) ≈ 58% of body width;
    // a little larger at tiny sizes for legibility.
    let markFraction: CGFloat = tiny ? 0.62 : (small ? 0.60 : 0.58)
    let barStroke: CGFloat = 0.10 * (tiny ? 1.45 : (small ? 1.15 : 1.0))
    let chevStroke: CGFloat = 0.12 * (tiny ? 1.35 : (small ? 1.12 : 1.0))
    let visibleUnitWidth: CGFloat = 0.60 + barStroke   // bar length + caps
    let box = bodySize * markFraction / visibleUnitWidth
    // Vertical visible extent in unit coords:
    let unitBottom = 0.24 - barStroke / 2
    let unitTopRound = 0.72 + chevStroke / 2
    let unitMid = (unitBottom + unitTopRound) / 2
    // Optical centre: nudge mark slightly above geometric centre.
    let opticalLift: CGFloat = bodySize * 0.012
    let cx = canvas / 2
    let cy = canvas / 2 + opticalLift
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: cx + (x - 0.5) * box, y: cy + (y - unitMid) * box)
    }

    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Lid bar. At small sizes snap its thickness and position to whole
    // device pixels so the horizontal edges stay crisp.
    var barWidth = barStroke * box
    var barY = P(0, 0.24).y
    if small {
        let wPx = max(1, (barWidth * scale).rounded())
        barWidth = wPx / scale
        // Round down: keeps a clear pixel gap under the chevron tips.
        let bottomPx = (barY * scale - wPx / 2).rounded(.down)
        barY = (bottomPx + wPx / 2) / scale
    }
    ctx.setLineWidth(barWidth)
    ctx.move(to: CGPoint(x: P(0.20, 0).x, y: barY))
    ctx.addLine(to: CGPoint(x: P(0.80, 0).x, y: barY))
    ctx.strokePath()

    // Up chevron
    ctx.setLineWidth(chevStroke * box)
    ctx.move(to: P(0.25, 0.47))
    ctx.addLine(to: P(0.50, 0.72))
    ctx.addLine(to: P(0.75, 0.47))
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write("failed writing \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    writePNG(render(pixels: px), to: outDir.appendingPathComponent(name))
}
print("Wrote \(specs.count) images to \(outDir.path)")
