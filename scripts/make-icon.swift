#!/usr/bin/env swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = size / 1024.0   // design at 1024 and scale down

    let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
    let bgPath = CGPath(
        roundedRect: bgRect.insetBy(dx: 40 * s, dy: 40 * s),
        cornerWidth: 200 * s, cornerHeight: 200 * s, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let colours = [
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colours, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }
    ctx.restoreGState()

    let islandW = 560 * s
    let islandH = 190 * s
    let islandX = (size - islandW) / 2
    let islandTop = size - 40 * s          // flush with the screen's top inset
    let islandRect = CGRect(x: islandX, y: islandTop - islandH, width: islandW, height: islandH)

    let r = 78 * s
    let island = CGMutablePath()
    island.move(to: CGPoint(x: islandRect.minX, y: islandRect.maxY))
    island.addLine(to: CGPoint(x: islandRect.minX, y: islandRect.minY + r))
    island.addArc(tangent1End: CGPoint(x: islandRect.minX, y: islandRect.minY),
                  tangent2End: CGPoint(x: islandRect.minX + r, y: islandRect.minY), radius: r)
    island.addLine(to: CGPoint(x: islandRect.maxX - r, y: islandRect.minY))
    island.addArc(tangent1End: CGPoint(x: islandRect.maxX, y: islandRect.minY),
                  tangent2End: CGPoint(x: islandRect.maxX, y: islandRect.minY + r), radius: r)
    island.addLine(to: CGPoint(x: islandRect.maxX, y: islandRect.maxY))
    island.closeSubpath()

    ctx.addPath(island)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()

    // Status dot — the one spot of colour. GitLab-running blue.
    let dotR = 46 * s
    let dotCentre = CGPoint(x: size / 2, y: islandRect.minY + islandH * 0.42)

    // Glow, so the dot still reads at 16pt where the shape itself is 3px tall.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40 * s,
                  color: NSColor(calibratedRed: 0.2, green: 0.55, blue: 1.0, alpha: 0.9).cgColor)
    ctx.setFillColor(NSColor(calibratedRed: 0.25, green: 0.6, blue: 1.0, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: dotCentre.x - dotR, y: dotCentre.y - dotR,
                               width: dotR * 2, height: dotR * 2))
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

for size in sizes {
    for scale in [1, 2] {
        let pixel = CGFloat(size * scale)
        let image = drawIcon(size: pixel)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        // iconutil only wants specific sizes; skip the ones it rejects.
        guard size <= 512 || scale == 1 else { continue }
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
print("wrote \(outDir)")
