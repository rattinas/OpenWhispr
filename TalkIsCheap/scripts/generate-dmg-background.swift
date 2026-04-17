#!/usr/bin/env swift
// Renders dmg-background.png (480x400 @2x) used by create-dmg.
// Single-action install UX: app icon centered, clear text below.

import AppKit
import CoreGraphics

let W: CGFloat = 480
let H: CGFloat = 400
let scale: CGFloat = 2

let pxW = Int(W * scale)
let pxH = Int(H * scale)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: pxW,
    height: pxH,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext init failed") }

ctx.scaleBy(x: scale, y: scale)

// Warm off-white gradient background
let bg1 = CGColor(red: 0.99, green: 0.98, blue: 0.97, alpha: 1)
let bg2 = CGColor(red: 0.94, green: 0.93, blue: 0.91, alpha: 1)
if let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [bg1, bg2] as CFArray,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: W/2, y: H),
        end: CGPoint(x: W/2, y: 0),
        options: []
    )
}

let nsGraphicsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsGraphicsContext

// ─── Title at top (centered) ─────────────────────────────
// Finder y=40 from top → CG y = H-40 = 360
let title = "TalkIsCheap"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1),
    .kern: 0.3,
]
let titleSize = (title as NSString).size(withAttributes: titleAttrs)
(title as NSString).draw(
    at: CGPoint(x: (W - titleSize.width) / 2, y: 340),
    withAttributes: titleAttrs
)

// ─── Primary instruction (below icon + filename label) ──────
// Icon lives at Finder y=150, size 112 → icon bottom y=206, filename label ~y=225.
// Place instruction at Finder y=275 → CG y = 400-275 = 125.
let instruction = "Double-click to install"
let instructionAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.75, alpha: 1),
    .kern: 0.3,
]
let instructionSize = (instruction as NSString).size(withAttributes: instructionAttrs)
(instruction as NSString).draw(
    at: CGPoint(x: (W - instructionSize.width) / 2, y: 110),
    withAttributes: instructionAttrs
)

// ─── Secondary hint ───────────────────────────────────
// Finder y=330 → CG y = 70
let hint = "I'll move myself to Applications and start setup"
let hintAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.44, blue: 0.42, alpha: 1),
    .kern: 0.1,
]
let hintSize = (hint as NSString).size(withAttributes: hintAttrs)
(hint as NSString).draw(
    at: CGPoint(x: (W - hintSize.width) / 2, y: 70),
    withAttributes: hintAttrs
)

NSGraphicsContext.restoreGraphicsState()

// Write PNG
guard let cgImage = ctx.makeImage() else { fatalError("makeImage failed") }
let bitmap = NSBitmapImageRep(cgImage: cgImage)
bitmap.size = NSSize(width: W, height: H)
guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("PNG encoding failed")
}

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dmg-background.png"
let url = URL(fileURLWithPath: outPath)
try pngData.write(to: url)
print("Wrote \(outPath) (\(pxW)x\(pxH) px)")
