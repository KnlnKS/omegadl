import AppKit
import Foundation

let megaRed = NSColor(srgbRed: 0xE6 / 255.0, green: 0x2B / 255.0, blue: 0x00 / 255.0, alpha: 1)
let circleScale = 0.98
let glyphHeight = 0.42 * circleScale
let glyphStroke = 0.115 * circleScale
let footExtent = 0.055 * circleScale
let gapHalfAngle = 44.0

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: CGSize(width: s, height: s))
    image.lockFocus()
    defer { image.unlockFocus() }
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = s * (1 - circleScale) / 2
    megaRed.setFill()
    NSBezierPath(ovalIn: CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)).fill()

    let height = s * glyphHeight
    let stroke = s * glyphStroke
    let endAngle = 270 - gapHalfAngle
    let sinEnd = abs(sin(endAngle * .pi / 180))
    let cosEnd = abs(cos(endAngle * .pi / 180))

    let radius = (height - stroke) / (1 + sinEnd)
    let cx = s / 2
    let footY = s / 2 - (height - stroke) / 2
    let cy = footY + radius * sinEnd

    NSColor.white.setStroke()
    NSColor.white.setFill()

    let bowl = NSBezierPath()
    bowl.appendArc(
        withCenter: CGPoint(x: cx, y: cy), radius: radius,
        startAngle: 270 + gapHalfAngle, endAngle: endAngle, clockwise: false
    )
    bowl.lineWidth = stroke
    bowl.lineCapStyle = .round
    bowl.stroke()

    let outer = radius + stroke / 2 + s * footExtent
    let inner = radius * cosEnd - stroke / 2
    for direction in [-1.0, 1.0] {
        let x0 = min(cx + direction * inner, cx + direction * outer)
        let x1 = max(cx + direction * inner, cx + direction * outer)
        NSBezierPath(
            roundedRect: CGRect(x: x0, y: footY - stroke / 2, width: x1 - x0, height: stroke),
            xRadius: stroke / 2, yRadius: stroke / 2
        ).fill()
    }

    return NSBitmapImageRep(focusedViewRect: CGRect(x: 0, y: 0, width: s, height: s))!
        .representation(using: .png, properties: [:])!
}

let outputDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                     ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                     ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512),
                     ("icon_512x512@2x", 1024)] {
    try! render(size: size).write(to: URL(filePath: "\(outputDir)/\(name).png"))
}
