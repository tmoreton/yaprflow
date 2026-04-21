#!/usr/bin/env swift
// Generates the AppIcon.appiconset PNGs for Yaprflow: white "waveform" SF Symbol
// on a black macOS-style rounded-rect background. Run once after changing the
// design; commit the produced PNGs.

import AppKit
import Foundation

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("yaprflow/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16.png", 16),
    ("icon_16@2x.png", 32),
    ("icon_32.png", 32),
    ("icon_32@2x.png", 64),
    ("icon_128.png", 128),
    ("icon_128@2x.png", 256),
    ("icon_256.png", 256),
    ("icon_256@2x.png", 512),
    ("icon_512.png", 512),
    ("icon_512@2x.png", 1024),
]

func render(pixelSize: Int) -> Data {
    let side = CGFloat(pixelSize)
    let rect = NSRect(x: 0, y: 0, width: side, height: side)

    let image = NSImage(size: rect.size, flipped: false) { r in
        let cornerRadius = side * 0.225

        let bg = NSBezierPath(roundedRect: r, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.black.setFill()
        bg.fill()

        let symbolPointSize = side * 0.60
        let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return false }

        let symSize = symbol.size
        let symRect = NSRect(
            x: (side - symSize.width) / 2,
            y: (side - symSize.height) / 2,
            width: symSize.width,
            height: symSize.height
        )
        symbol.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        return true
    }

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG export failed for \(pixelSize)")
    }
    return png
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for (name, px) in sizes {
    let url = outputDir.appendingPathComponent(name)
    try render(pixelSize: px).write(to: url)
    print("\(name): \(px)×\(px)")
}

// Update Contents.json to reference the PNGs.
let contents: [String: Any] = [
    "images": [
        ["idiom": "mac", "scale": "1x", "size": "16x16", "filename": "icon_16.png"],
        ["idiom": "mac", "scale": "2x", "size": "16x16", "filename": "icon_16@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "32x32", "filename": "icon_32.png"],
        ["idiom": "mac", "scale": "2x", "size": "32x32", "filename": "icon_32@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128.png"],
        ["idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256.png"],
        ["idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512.png"],
        ["idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512@2x.png"],
    ],
    "info": ["author": "xcode", "version": 1],
]

let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDir.appendingPathComponent("Contents.json"))

print("Done.")
