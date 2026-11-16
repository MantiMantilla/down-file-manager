#!/usr/bin/env swift
// Renders Down's PLACEHOLDER app icon into App/Assets.xcassets/AppIcon.appiconset.
//   swift scripts/make-placeholder-icon.swift
//
// A rounded-square gradient with a white folder and a down arrow, on the standard macOS icon grid
// (824 pt body inside a 1024 pt canvas). Replace it with a real design (e.g. an Icon Composer .icon)
// when there is one; this only exists so the app isn't iconless.
import AppKit

let root = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appending(path: "App/Assets.xcassets/AppIcon.appiconset")

func render(pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no bitmap context") }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    // Draw in 1024-unit design space.
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    let top = NSColor(srgbRed: 0.33, green: 0.62, blue: 0.98, alpha: 1)
    let bottom = NSColor(srgbRed: 0.13, green: 0.36, blue: 0.82, alpha: 1)
    NSGradient(starting: bottom, ending: top)?.draw(in: shape, angle: 90)

    let white = NSImage.SymbolConfiguration(paletteColors: [.white])
    if let folder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 400, weight: .regular).applying(white)) {
        let size = folder.size
        let width: CGFloat = 560
        let height = width * size.height / size.width
        folder.draw(in: NSRect(x: 512 - width / 2, y: 470 - height / 2, width: width, height: height))
    }
    let arrowColor = NSImage.SymbolConfiguration(paletteColors: [bottom])
    if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 200, weight: .bold).applying(arrowColor)) {
        let size = arrow.size
        let height: CGFloat = 250
        let width = height * size.width / size.height
        arrow.draw(in: NSRect(x: 512 - width / 2, y: 440 - height / 2, width: width, height: height))
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    return png
}

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        try render(pixels: points * factor).write(to: iconSet.appending(path: name))
        images.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(factor)x", "size" : "\(points)x\(points)" }
        """)
    }
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try contents.write(to: iconSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(images.count) placeholder icon PNGs to \(iconSet.path(percentEncoded: false))")
