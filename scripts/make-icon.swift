// Renders Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        let s = size / 1024
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        // Squircle background with the standard macOS icon inset.
        let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(tilePath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        let background = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(red: 0.36, green: 0.62, blue: 1.0, alpha: 1).cgColor,
                NSColor(red: 0.13, green: 0.33, blue: 0.93, alpha: 1).cgColor,
            ] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])

        // The island, hanging from the top edge.
        let island = CGRect(x: 212 * s, y: 100 * s, width: 600 * s, height: 300 * s)
        let islandPath = CGMutablePath()
        let r: CGFloat = 110 * s
        islandPath.move(to: CGPoint(x: island.minX, y: island.minY))
        islandPath.addLine(to: CGPoint(x: island.maxX, y: island.minY))
        islandPath.addLine(to: CGPoint(x: island.maxX, y: island.maxY - r))
        islandPath.addQuadCurve(to: CGPoint(x: island.maxX - r, y: island.maxY), control: CGPoint(x: island.maxX, y: island.maxY))
        islandPath.addLine(to: CGPoint(x: island.minX + r, y: island.maxY))
        islandPath.addQuadCurve(to: CGPoint(x: island.minX, y: island.maxY - r), control: CGPoint(x: island.minX, y: island.maxY))
        islandPath.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 18 * s), blur: 40 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(islandPath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // A document inside the island.
        let doc = CGRect(x: 282 * s, y: 196 * s, width: 104 * s, height: 132 * s)
        ctx.addPath(CGPath(roundedRect: doc, cornerWidth: 14 * s, cornerHeight: 14 * s, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.setFillColor(NSColor(white: 0.78, alpha: 1).cgColor)
        for i in 0..<4 {
            let w: CGFloat = i == 3 ? 40 : 64
            ctx.fill(CGRect(x: doc.minX + 20 * s, y: doc.minY + CGFloat(28 + i * 22) * s, width: w * s, height: 9 * s))
        }

        // Name and subtitle lines.
        ctx.addPath(CGPath(roundedRect: CGRect(x: 416 * s, y: 222 * s, width: 180 * s, height: 26 * s), cornerWidth: 13 * s, cornerHeight: 13 * s, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: CGRect(x: 416 * s, y: 270 * s, width: 120 * s, height: 22 * s), cornerWidth: 11 * s, cornerHeight: 11 * s, transform: nil))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.4).cgColor)
        ctx.fillPath()

        // Green "downloaded" badge.
        let badge = CGRect(x: 644 * s, y: 212 * s, width: 100 * s, height: 100 * s)
        ctx.setFillColor(NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1).cgColor)
        ctx.fillEllipse(in: badge)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(12 * s)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: badge.midX, y: badge.minY + 26 * s))
        ctx.addLine(to: CGPoint(x: badge.midX, y: badge.maxY - 26 * s))
        ctx.move(to: CGPoint(x: badge.midX - 20 * s, y: badge.maxY - 46 * s))
        ctx.addLine(to: CGPoint(x: badge.midX, y: badge.maxY - 26 * s))
        ctx.addLine(to: CGPoint(x: badge.midX + 20 * s, y: badge.maxY - 46 * s))
        ctx.strokePath()

        // A big tray arrow below the island.
        if let symbol = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 300 * s, weight: .semibold)) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                NSColor.white.withAlphaComponent(0.95).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let rect = CGRect(x: 512 * s - tinted.size.width / 2, y: 470 * s, width: tinted.size.width, height: tinted.size.height)
            tinted.draw(in: rect)
        }
        ctx.restoreGState()
        return true
    }
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let image = draw(size: pixels)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
print("Wrote \(output.path)")
