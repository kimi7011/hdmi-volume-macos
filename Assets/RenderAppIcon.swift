import AppKit

// Draw on a 1024-point canvas and render the same artwork at each iconset size.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: alpha)
}

func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                 xRadius: radius, yRadius: radius)
}

func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}

func shade(_ path: NSBezierPath, _ light: UInt32, _ dark: UInt32, angle: CGFloat = -68) {
    NSGradient(starting: color(light), ending: color(dark))!.draw(in: path, angle: angle)
}

func stroke(_ path: NSBezierPath, _ paint: NSColor, width: CGFloat) {
    paint.setStroke()
    path.lineWidth = width
    path.stroke()
}

func drawSpeaker() {
    let backing = box(61, 63, 902, 902, 210)
    shade(backing, 0x304961, 0x101D2C)

    // Broad blue reflection follows the upper-left edge of the dark glass.
    NSGradient(starting: color(0x82B9DE, alpha: 0.35), ending: color(0x82B9DE, alpha: 0))!
        .draw(in: backing, relativeCenterPosition: NSPoint(x: -0.95, y: 0.95))
    stroke(box(64, 66, 896, 896, 207), color(0xB7D9F1, alpha: 0.26), width: 4)

    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.setShadow(offset: CGSize(width: 8, height: -18), blur: 35, color: color(0x000B19, alpha: 0.66).cgColor)
    color(0x0B1725).setFill()
    box(317, 224, 410, 573, 81).fill()
    context.restoreGState()

    // Offset and round one side of the cabinet to give the faceplate depth.
    shade(box(327, 228, 401, 564, 78), 0x557F9D, 0x12273C, angle: -80)
    shade(box(297, 251, 405, 556, 76), 0xAAC5DA, 0x3A576F)
    shade(box(308, 262, 383, 534, 65), 0x55768E, 0x213649)
    stroke(box(312, 266, 375, 526, 62), color(0xDEEFFC, alpha: 0.24), width: 3)

    // A bright tweeter above a larger, recessed woofer.
    shade(circle(500, 673, 70), 0x172B40, 0x8DACC3)
    shade(circle(500, 673, 57), 0xD0E8FA, 0x496C88)
    shade(circle(500, 673, 39), 0x1B364D, 0x5B819F)
    shade(circle(500, 675, 22), 0xB5D3E9, 0x577D9A)

    shade(circle(500, 454, 147), 0x14273A, 0x7598B3)
    shade(circle(500, 454, 134), 0xBADBED, 0x527A99)
    shade(circle(500, 454, 115), 0x102438, 0x4C708E)
    shade(circle(500, 454, 94), 0x658EAC, 0x263F58, angle: 114)
    stroke(circle(500, 454, 96), color(0xC1E6F9, alpha: 0.29), width: 3)
    shade(circle(500, 457, 47), 0x8BB3D0, 0x354F6A)
    stroke(circle(500, 457, 46), color(0x163148, alpha: 0.53), width: 3)

    let indicator = box(469, 282, 62, 13, 6.5)
    shade(indicator, 0xA6EDFC, 0x4FB8E0, angle: -90)
}

guard CommandLine.arguments.count == 2 else {
    print("Usage: swift Assets/RenderAppIcon.swift AppIcon.iconset")
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = pointSize * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawSpeaker()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let file = output.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }
}
