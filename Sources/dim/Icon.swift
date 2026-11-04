import CoreGraphics
import DiskCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `dim icon <out.iconset>`: draws the app icon, a treemap of soft cushions, at every size macOS
/// asks for. Drawing each size from scratch keeps the small ones crisp.
func runIcon(_ arguments: [String]) throws {
    guard let output = arguments.first else { throw ScanError.cannotOpen(path: "(need <out.iconset>)", code: EINVAL) }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

    let variants: [(name: String, size: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for variant in variants {
        let image = try drawIcon(size: variant.size)
        let url = URL(fileURLWithPath: output).appendingPathComponent(variant.name + ".png") as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
            throw ScanError.cannotOpen(path: output, code: EIO)
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let components = [
        CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha,
    ]
    return CGColor(colorSpace: sRGB, components: components)!
}

/// The shape of a macOS icon: a rounded square whose corners ease into its sides.
private func iconShape(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    // Each corner in its own frame: `u` runs along the side arriving at it, `v` along the one leaving it.
    func corner(_ c: CGPoint, _ u: CGPoint, _ v: CGPoint) {
        func point(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: c.x + (u.x * a + v.x * b) * r, y: c.y + (u.y * a + v.y * b) * r)
        }
        path.addLine(to: point(-1.528665, 0))
        path.addCurve(to: point(-0.63149379, 0.07491139), control1: point(-1.08849296, 0), control2: point(-0.86840694, 0))
        path.addCurve(to: point(-0.07491139, 0.63149379), control1: point(-0.37282383, 0.16905956), control2: point(-0.16905956, 0.37282383))
        path.addCurve(to: point(0, 1.52866498), control1: point(0, 0.86840694), control2: point(0, 1.08849296))
    }
    path.move(to: CGPoint(x: rect.minX + 1.528665 * r, y: rect.minY))
    corner(CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1))
    corner(CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0))
    corner(CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: -1))
    corner(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0))
    path.closeSubpath()
    return path
}

/// Draws on the standard macOS grid: a canvas of 1024 with a body of 824 in the middle.
private func drawIcon(size: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw ScanError.outOfMemory }
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = iconShape(body, radius: 185.4)

    // Shadows ignore the scale of the context, so they get theirs by hand.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: color(0x000000, alpha: 0.34))
    context.addPath(shape)
    context.setFillColor(color(0x000000))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.setFillColor(color(0x0D0F1A))
    context.fill(body)

    // A treemap with the same families as the map: video, audio, apps, photos, archives, documents.
    let cushions: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, light: UInt32, deep: UInt32)] = [
        (0, 0, 0.60, 0.62, 0x4FB2FF, 0x1F63E0),
        (0.60, 0, 0.40, 0.36, 0xD09BFF, 0x8A3FE0),
        (0.60, 0.36, 0.40, 0.26, 0xFF7FA6, 0xE5336F),
        (0, 0.62, 0.40, 0.38, 0x5FE3A1, 0x0E9F62),
        (0.40, 0.62, 0.34, 0.38, 0xFFB45C, 0xF0701F),
        (0.74, 0.62, 0.26, 0.38, 0xFFE27A, 0xF2B91E),
    ]
    let gap: CGFloat = 7
    for cushion in cushions {
        let rect = CGRect(
            x: body.minX + cushion.x * body.width + gap / 2,
            y: body.minY + cushion.y * body.height + gap / 2,
            width: cushion.width * body.width - gap,
            height: cushion.height * body.height - gap
        )
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.clip()
        context.setFillColor(color(cushion.deep))
        context.fill(rect)
        let glow = CGGradient(
            colorsSpace: sRGB,
            colors: [color(cushion.light), color(cushion.light, alpha: 0.75), color(cushion.light, alpha: 0)] as CFArray,
            locations: [0, 0.42, 1]
        )!
        let center = CGPoint(x: rect.midX - rect.width * 0.08, y: rect.midY - rect.height * 0.12)
        context.drawRadialGradient(
            glow, startCenter: center, startRadius: 0, endCenter: center,
            endRadius: max(rect.width, rect.height) * 0.80, options: []
        )
        context.restoreGState()
    }

    context.addPath(shape)
    context.setLineWidth(5)
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.16))
    context.strokePath()
    context.restoreGState()

    guard let image = context.makeImage() else { throw ScanError.outOfMemory }
    return image
}
