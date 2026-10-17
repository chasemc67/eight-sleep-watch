// Draws the 1024×1024 app icon (no alpha) and writes it into the iOS and watch asset catalogs.
// Usage: swift Tools/make_icon.swift   (run from the repo root)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let s = CGFloat(size)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Navy → indigo diagonal gradient.
let gradient = CGGradient(colorsSpace: space, colors: [color(0x0A1633), color(0x1E2A6B), color(0x4B2FA3)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Bed (CoreGraphics origin is bottom-left); shifted to optically center the artwork.
ctx.translateBy(x: 22, y: -55)
ctx.setFillColor(color(0xFFFFFF))
ctx.addPath(roundedRect(CGRect(x: 170, y: 300, width: 56, height: 400), 28))   // headboard post
ctx.addPath(roundedRect(CGRect(x: 170, y: 380, width: 640, height: 150), 40))  // mattress
ctx.addPath(roundedRect(CGRect(x: 760, y: 300, width: 50, height: 230), 25))   // foot post
ctx.fillPath()
ctx.setFillColor(color(0xFFFFFF, 0.92))
ctx.addPath(roundedRect(CGRect(x: 250, y: 545, width: 190, height: 95), 44))   // pillow
ctx.fillPath()
ctx.setFillColor(color(0x9FB4FF))
ctx.addPath(roundedRect(CGRect(x: 460, y: 530, width: 350, height: 60), 30))  // blanket
ctx.fillPath()

// Warm/cool waves above the bed.
ctx.setLineCap(.round)
ctx.setLineWidth(26)
for (i, hex) in [UInt32(0x6FC3FF), 0xFF9A5A].enumerated() {
    let y = CGFloat(720 + i * 80)
    ctx.setStrokeColor(color(hex))
    ctx.move(to: CGPoint(x: 300, y: y))
    ctx.addCurve(to: CGPoint(x: 720, y: y), control1: CGPoint(x: 440, y: y + 70), control2: CGPoint(x: 580, y: y - 70))
    ctx.strokePath()
}

let image = ctx.makeImage()!
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
for dir in ["iOS/Assets.xcassets/AppIcon.appiconset", "Watch/Assets.xcassets/AppIcon.appiconset"] {
    let url = root.appendingPathComponent(dir).appendingPathComponent("AppIcon.png")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("failed to write \(url.path)") }
    print("wrote \(dir)/AppIcon.png")
}
