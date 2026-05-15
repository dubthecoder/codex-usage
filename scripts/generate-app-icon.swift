import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.icns"
let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
let outputURL = URL(fileURLWithPath: outputPath)

try? fileManager.removeItem(at: iconset)
try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    let image = drawIcon(size: size)
    let url = iconset.appendingPathComponent(name)
    try writePNG(image, to: url)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "IconGeneration", code: Int(process.terminationStatus), userInfo: [
        NSLocalizedDescriptionKey: "iconutil failed"
    ])
}

func drawIcon(size: Int) -> NSImage {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let scale = CGFloat(size) / 1024.0
    let image = NSImage(size: rect.size)

    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else {
        return image
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let corner = 224 * scale
    let outer = CGPath(roundedRect: CGRect(x: 28 * scale, y: 28 * scale, width: 968 * scale, height: 968 * scale), cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.addPath(outer)
    context.clip()

    let colors = [
        NSColor(red: 0.038, green: 0.043, blue: 0.040, alpha: 1).cgColor,
        NSColor(red: 0.098, green: 0.113, blue: 0.103, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    context.resetClip()
    context.addPath(outer)
    context.setStrokeColor(NSColor(red: 0.34, green: 0.38, blue: 0.35, alpha: 0.55).cgColor)
    context.setLineWidth(18 * scale)
    context.strokePath()

    drawCodexMark(in: context, scale: scale)
    drawPrompt(in: context, scale: scale)

    return image
}

func drawCodexMark(in context: CGContext, scale: CGFloat) {
    let green = NSColor(red: 0.06, green: 0.72, blue: 0.56, alpha: 1).cgColor
    let muted = NSColor(red: 0.58, green: 0.72, blue: 0.66, alpha: 0.32).cgColor
    let center = CGPoint(x: 512 * scale, y: 594 * scale)
    let radius = 186 * scale
    let lineWidth = 56 * scale

    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(lineWidth)

    for index in 0..<6 {
        let rotation = CGFloat(index) * .pi / 3
        let start = rotation + 0.15
        let end = rotation + 0.86
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.setStrokeColor(index == 0 || index == 3 ? green : muted)
        context.strokePath()
    }

    context.setFillColor(NSColor(red: 0.06, green: 0.72, blue: 0.56, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: 486 * scale, y: 568 * scale, width: 52 * scale, height: 52 * scale))
}

func drawPrompt(in context: CGContext, scale: CGFloat) {
    let text = ">_"
    let fontSize = 185 * scale
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: NSColor(red: 0.91, green: 0.95, blue: 0.91, alpha: 1),
        .paragraphStyle: paragraph,
    ]

    let attributed = NSAttributedString(string: text, attributes: attributes)
    attributed.draw(in: NSRect(x: 0, y: 214 * scale, width: 1024 * scale, height: 220 * scale))
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconGeneration", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not encode PNG"
        ])
    }

    try data.write(to: url)
}
