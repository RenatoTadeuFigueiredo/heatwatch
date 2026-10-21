import AppKit
import Foundation

// Renders the app icon: a dark rounded tile with the same green/yellow/red
// dots the menu bar uses.

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    let tile = NSBezierPath(roundedRect: NSRect(x: side * 0.06, y: side * 0.06,
                                                width: side * 0.88, height: side * 0.88),
                            xRadius: side * 0.2, yRadius: side * 0.2)
    let background = NSGradient(colors: [
        NSColor(calibratedWhite: 0.16, alpha: 1),
        NSColor(calibratedWhite: 0.06, alpha: 1)
    ])
    background?.draw(in: tile, angle: -90)

    let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
    let radius = side * 0.085
    for (index, color) in colors.enumerated() {
        let centerY = side * (0.7 - CGFloat(index) * 0.2)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: side / 2 - radius, y: centerY - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }

    image.unlockFocus()

    let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return representation.representation(using: .png, properties: [:])!
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, size) in variants {
    try! draw(size: size).write(to: iconset.appendingPathComponent("\(name).png"))
}

print(iconset.path)
