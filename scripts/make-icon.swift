// Renders the Chillar app icon (a small stack of rupee coins) to a 1024px PNG.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func linear(_ colors: [NSColor], in rect: NSRect, angle: CGFloat, clip: NSBezierPath) {
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    NSGradient(colors: colors)?.draw(in: rect, angle: angle)
    NSGraphicsContext.restoreGraphicsState()
}

/// One coin seen face-on, with a rim, an inner ring and an optional ₹.
func coin(center c: NSPoint, radius r: CGFloat, rupee: Bool) {
    let disc = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))

    // Soft shadow under each coin so the stack reads as layered.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x0A3D26, 0.35)
    shadow.shadowBlurRadius = r * 0.10
    shadow.shadowOffset = NSSize(width: 0, height: -r * 0.05)
    shadow.set()
    color(0xC9971F).setFill()
    disc.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Rim and face.
    linear([color(0xF6D365), color(0xE0A82E), color(0xB98316)], in: disc.bounds, angle: -60, clip: disc)
    let ri = r * 0.84
    let face = NSBezierPath(ovalIn: NSRect(x: c.x - ri, y: c.y - ri, width: 2 * ri, height: 2 * ri))
    linear([color(0xFBE08A), color(0xF0BE45)], in: face.bounds, angle: -70, clip: face)
    color(0xB98316, 0.55).setStroke()
    face.lineWidth = r * 0.035
    face.stroke()

    guard rupee else { return }
    let font = NSFont.systemFont(ofSize: r * 1.18, weight: .heavy)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let glyph = NSAttributedString(string: "₹", attributes: [
        .font: font, .foregroundColor: color(0x9A6A0E), .paragraphStyle: para,
    ])
    let gs = glyph.size()
    // Debossed look: a light offset copy under the dark glyph.
    let light = NSAttributedString(string: "₹", attributes: [
        .font: font, .foregroundColor: color(0xFFF1BF, 0.9), .paragraphStyle: para,
    ])
    let origin = NSPoint(x: c.x - gs.width / 2, y: c.y - gs.height / 2 - r * 0.02)
    light.draw(at: NSPoint(x: origin.x + r * 0.015, y: origin.y - r * 0.02))
    glyph.draw(at: origin)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: 824pt body inset 100pt, continuous-corner squircle.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.28)
    drop.shadowBlurRadius = 28
    drop.shadowOffset = NSSize(width: 0, height: -12)
    drop.set()
    color(0x0E7A4A).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    linear([color(0x22A66A), color(0x0F7A4B), color(0x0A5C38)], in: body, angle: -90, clip: squircle)
    // Faint top sheen.
    linear([NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)],
           in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2),
           angle: -90, clip: squircle)

    // Loose change: a smaller coin tucked behind, the ₹ coin in front.
    coin(center: NSPoint(x: 668, y: 660), radius: 172, rupee: false)
    coin(center: NSPoint(x: 470, y: 455), radius: 262, rupee: true)
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
