// Original geometric artwork; no external images or font assets required.
// Run on macOS: swift scripts/create-icon.swift
import Foundation
import CoreGraphics
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let colorSpace = CGColorSpaceCreateDeviceRGB()
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255, g / 255, b / 255, 1])!
}
func render(size: Int, to relativePath: String) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    let gradient = CGGradient(colorsSpace: colorSpace,
        colors: [color(94, 73, 190), color(47, 36, 102)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 850, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.setFillColor(color(246, 244, 255))
    context.addPath(CGPath(roundedRect: CGRect(x: 186, y: 225, width: 652, height: 504), cornerWidth: 142, cornerHeight: 142, transform: nil)); context.fillPath()
    let tail = CGMutablePath(); tail.move(to: CGPoint(x: 278, y: 662)); tail.addLine(to: CGPoint(x: 278, y: 810)); tail.addQuadCurve(to: CGPoint(x: 472, y: 707), control: CGPoint(x: 371, y: 792)); tail.closeSubpath()
    context.addPath(tail); context.fillPath()
    context.setStrokeColor(color(78, 60, 158)); context.setLineWidth(43); context.setLineCap(.round); context.setLineJoin(.round)
    context.move(to: CGPoint(x: 339, y: 406)); context.addLine(to: CGPoint(x: 413, y: 477)); context.addLine(to: CGPoint(x: 339, y: 548)); context.strokePath()
    context.move(to: CGPoint(x: 494, y: 548)); context.addLine(to: CGPoint(x: 621, y: 548)); context.strokePath()
    context.setFillColor(color(166, 239, 196)); context.fillEllipse(in: CGRect(x: 714, y: 193, width: 122, height: 122))
    let destination = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Could not write icon") }
}
try render(size: 1024, to: "ios/HarnessPocket/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try render(size: 256, to: "docs/images/icon.png")
print("Generated app and README icons.")
