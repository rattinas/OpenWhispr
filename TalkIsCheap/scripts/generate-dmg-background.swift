#!/usr/bin/env swift
// Renders dmg-background.png (540x380 @2x = 1080x760) used by create-dmg.
// Clean, modern design: warm off-white, subtle vignette, arrow + hint text.

import AppKit
import CoreGraphics

let W: CGFloat = 540
let H: CGFloat = 380
let scale: CGFloat = 2  // retina

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

// Background: soft warm gradient (top slightly lighter)
let bg1 = CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
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

// Subtle horizontal rule
ctx.setStrokeColor(red: 0.85, green: 0.84, blue: 0.82, alpha: 0.6)
ctx.setLineWidth(0.5)
ctx.move(to: CGPoint(x: 40, y: H - 70))
ctx.addLine(to: CGPoint(x: W - 40, y: H - 70))
ctx.strokePath()

// Use NSGraphicsContext for text so we can use AppKit string drawing
let nsGraphicsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsGraphicsContext

// Title
let titleColor = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
let title = "TalkIsCheap"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
    .foregroundColor: titleColor,
    .kern: 0.2,
]
let titleSize = (title as NSString).size(withAttributes: titleAttrs)
(title as NSString).draw(
    at: CGPoint(x: (W - titleSize.width) / 2, y: H - 50),
    withAttributes: titleAttrs
)

// Hint text below the icons
let hintColor = NSColor(calibratedRed: 0.45, green: 0.44, blue: 0.42, alpha: 1)
let hint = "Drag TalkIsCheap into the Applications folder"
let hintAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: hintColor,
    .kern: 0.1,
]
let hintSize = (hint as NSString).size(withAttributes: hintAttrs)
(hint as NSString).draw(
    at: CGPoint(x: (W - hintSize.width) / 2, y: 40),
    withAttributes: hintAttrs
)

// Arrow between icon positions (roughly x=140 and x=400, y≈190)
let arrowY: CGFloat = 190
let arrowStartX: CGFloat = 210
let arrowEndX: CGFloat = 330
let arrowColor = NSColor(calibratedRed: 0.55, green: 0.52, blue: 0.48, alpha: 0.85)
arrowColor.setStroke()
arrowColor.setFill()

let arrowPath = NSBezierPath()
arrowPath.lineWidth = 2
arrowPath.lineCapStyle = .round
arrowPath.move(to: CGPoint(x: arrowStartX, y: arrowY))
arrowPath.line(to: CGPoint(x: arrowEndX, y: arrowY))
arrowPath.stroke()

// Arrowhead
let head = NSBezierPath()
head.lineWidth = 2
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: CGPoint(x: arrowEndX - 10, y: arrowY + 6))
head.line(to: CGPoint(x: arrowEndX, y: arrowY))
head.line(to: CGPoint(x: arrowEndX - 10, y: arrowY - 6))
head.stroke()

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
