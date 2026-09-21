// Creates a simple .icns icon for Android Mirroring
// Run: swift scripts/create_icon.swift <output.icns>

import AppKit
import Foundation

func createPhoneIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Background - subtle dark gradient like macOS app icons
    let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
    let gradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.15, alpha: 1),
        NSColor(calibratedWhite: 0.25, alpha: 1),
    ])
    // Clip to the squircle so the corners stay transparent.
    gradient?.draw(in: NSBezierPath(roundedRect: bgRect, xRadius: size * 0.21, yRadius: size * 0.21),
                   angle: -90)

    // Rounded rect background (macOS icon squircle approximation)
    let cornerRadius = size * 0.185
    let iconPath = NSBezierPath(roundedRect: bgRect.insetBy(dx: size * 0.03, dy: size * 0.03),
                                xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
    iconPath.fill()

    // Phone shape
    let phoneWidth = size * 0.42
    let phoneHeight = size * 0.65
    let phoneX = (size - phoneWidth) / 2
    let phoneY = (size - phoneHeight) / 2
    let phoneRect = NSRect(x: phoneX, y: phoneY, width: phoneWidth, height: phoneHeight)
    let phoneRadius = phoneWidth * 0.18

    // Phone body
    let phonePath = NSBezierPath(roundedRect: phoneRect, xRadius: phoneRadius, yRadius: phoneRadius)
    NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
    phonePath.fill()

    // Phone screen
    let screenInset = phoneWidth * 0.06
    let screenRect = phoneRect.insetBy(dx: screenInset, dy: screenInset)
    let screenRadius = phoneRadius * 0.6
    let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: screenRadius, yRadius: screenRadius)

    // Screen gradient (Android green to teal)
    let screenGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.2, green: 0.7, blue: 0.4, alpha: 1),
        NSColor(calibratedRed: 0.1, green: 0.5, blue: 0.6, alpha: 1),
    ])
    screenGradient?.draw(in: screenPath, angle: -60)

    // Dynamic island / camera punch hole
    let islandWidth = screenRect.width * 0.3
    let islandHeight = screenRect.height * 0.025
    let islandRect = NSRect(x: screenRect.midX - islandWidth / 2,
                            y: screenRect.maxY - islandHeight - screenInset,
                            width: islandWidth, height: islandHeight)
    let islandPath = NSBezierPath(roundedRect: islandRect, xRadius: islandHeight / 2, yRadius: islandHeight / 2)
    NSColor.black.setFill()
    islandPath.fill()

    image.unlockFocus()
    return image
}

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.icns"

let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

// Write each size as PNG to a temp dir, then use iconutil
let tempDir = NSTemporaryDirectory() + "/iconbuild.\(UUID().uuidString).iconset"
try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

for (size, name) in sizes {
    let icon = createPhoneIcon(size: size)
    if let tiff = icon.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: "\(tempDir)/\(name).png"))
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", tempDir, "-o", output]
try! process.run()
process.waitUntilExit()

// Cleanup
try? FileManager.default.removeItem(atPath: tempDir)

if process.terminationStatus == 0 {
    print("Created \(output)")
} else {
    print("iconutil failed with status \(process.terminationStatus)")
    exit(1)
}
