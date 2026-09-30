// Usage: swift scripts/make-readme-icon.swift hibari/Assets.xcassets/AppIcon.appiconset/AppIcon.png docs/icon.png
import AppKit
import CoreGraphics
import Foundation

let src = CommandLine.arguments[1], dst = CommandLine.arguments[2]
let size = 512.0, pad = 24.0          // canvas and room for the shadow
let icon = size - pad * 2
guard let img = NSImage(contentsOfFile: src)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

// Superellipse (n=5) approximates iOS's continuous-corner icon shape
let path = CGMutablePath()
let n = 5.0, r = icon / 2, c = size / 2
for i in 0...720 {
    let t = Double(i) / 720 * 2 * .pi
    let x = c + r * copysign(pow(abs(cos(t)), 2 / n), cos(t))
    let y = c + r * copysign(pow(abs(sin(t)), 2 / n), sin(t))
    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
}
path.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: CGColor(gray: 0, alpha: 0.25))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

ctx.addPath(path); ctx.clip()
ctx.draw(img, in: CGRect(x: pad, y: pad, width: icon, height: icon))

let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dst))
