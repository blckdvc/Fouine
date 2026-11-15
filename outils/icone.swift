// Dessine l'icône de Fouine (une fouine vue à travers une loupe) et écrit un PNG 1024 × 1024.
// Usage : swift outils/icone.swift chemin/sortie.png   — voir outils/icone.sh pour le .icns.
import AppKit

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
}

// Fond : carré arrondi aux proportions des icônes macOS (824 px sur un canevas de 1024), avec ombre.
let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35).cgColor)
color(0x1F2A4D).setFill()
plate.fill()
ctx.restoreGState()
NSGradient(colors: [color(0x18213F), color(0x2F4A8F), color(0x4C78C8)])!.draw(in: plate, angle: 90)

// Loupe : manche d'abord, pour que l'anneau le recouvre.
let lens = CGPoint(x: 462, y: 566)
let radius: CGFloat = 252
let handle = NSBezierPath()
handle.move(to: CGPoint(x: lens.x + radius * 0.74, y: lens.y - radius * 0.74))
handle.line(to: CGPoint(x: 792, y: 236))
handle.lineWidth = 84
handle.lineCapStyle = .round
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.3).cgColor)
color(0xF4F6FB).setStroke()
handle.stroke()
ctx.restoreGState()

// Verre et fouine, découpés dans le cercle de la lentille.
let glass = ellipse(lens.x, lens.y, radius, radius)
ctx.saveGState()
glass.addClip()
NSGradient(colors: [color(0xBFD6F5), color(0xEAF2FF)])!.draw(in: glass, angle: 90)

let fur = color(0x8A5A3A), furDark = color(0x6E452B), cream = color(0xF7E9D3), ink = color(0x1C1A1D)
// Oreilles hautes, à liseré clair
for dx in [-108.0, 108.0] {
    furDark.setFill(); ellipse(lens.x + dx, lens.y + 158, 56, 84).fill()
    cream.setFill(); ellipse(lens.x + dx, lens.y + 156, 34, 60).fill()
    color(0xD9A98A).setFill(); ellipse(lens.x + dx, lens.y + 148, 24, 48).fill()
}
// Plastron clair de la fouine, sous le menton
cream.setFill(); ellipse(lens.x, lens.y - 262, 138, 120).fill()
// Tête en coin : front large, museau fin et pointu
let head = NSBezierPath()
head.move(to: CGPoint(x: lens.x - 150, y: lens.y + 66))
head.curve(to: CGPoint(x: lens.x, y: lens.y + 168),
           controlPoint1: CGPoint(x: lens.x - 150, y: lens.y + 140), controlPoint2: CGPoint(x: lens.x - 80, y: lens.y + 168))
head.curve(to: CGPoint(x: lens.x + 150, y: lens.y + 66),
           controlPoint1: CGPoint(x: lens.x + 80, y: lens.y + 168), controlPoint2: CGPoint(x: lens.x + 150, y: lens.y + 140))
head.curve(to: CGPoint(x: lens.x, y: lens.y - 176),
           controlPoint1: CGPoint(x: lens.x + 150, y: lens.y - 30), controlPoint2: CGPoint(x: lens.x + 52, y: lens.y - 176))
head.curve(to: CGPoint(x: lens.x - 150, y: lens.y + 66),
           controlPoint1: CGPoint(x: lens.x - 52, y: lens.y - 176), controlPoint2: CGPoint(x: lens.x - 150, y: lens.y - 30))
head.close()
fur.setFill(); head.fill()
// Masque plus sombre autour des yeux
ctx.saveGState()
head.addClip()
furDark.setFill()
ellipse(lens.x - 72, lens.y + 22, 62, 44).fill()
ellipse(lens.x + 72, lens.y + 22, 62, 44).fill()
// Museau clair, étroit
cream.setFill()
let muzzle = NSBezierPath()
muzzle.move(to: CGPoint(x: lens.x, y: lens.y - 6))
muzzle.curve(to: CGPoint(x: lens.x, y: lens.y - 176),
             controlPoint1: CGPoint(x: lens.x + 86, y: lens.y - 60), controlPoint2: CGPoint(x: lens.x + 60, y: lens.y - 176))
muzzle.curve(to: CGPoint(x: lens.x, y: lens.y - 6),
             controlPoint1: CGPoint(x: lens.x - 60, y: lens.y - 176), controlPoint2: CGPoint(x: lens.x - 86, y: lens.y - 60))
muzzle.fill()
ctx.restoreGState()
// Yeux
for dx in [-72.0, 72.0] {
    ink.setFill(); ellipse(lens.x + dx, lens.y + 22, 21, 23).fill()
    NSColor.white.setFill(); ellipse(lens.x + dx + 7, lens.y + 31, 7, 7).fill()
}
// Truffe au bout du museau
ink.setFill(); ellipse(lens.x, lens.y - 138, 24, 18).fill()
// Moustaches
let whiskers = NSBezierPath()
for side in [-1.0, 1.0] {
    for dy in [-8.0, 14.0] {
        whiskers.move(to: CGPoint(x: lens.x + side * 34, y: lens.y - 112))
        whiskers.line(to: CGPoint(x: lens.x + side * 132, y: lens.y - 104 + dy * 2))
    }
}
whiskers.lineWidth = 4
whiskers.lineCapStyle = .round
color(0xFFFFFF, 0.9).setStroke(); whiskers.stroke()
// Reflet du verre
let shine = NSBezierPath()
shine.appendArc(withCenter: lens, radius: radius - 44, startAngle: 112, endAngle: 158)
shine.lineWidth = 20
shine.lineCapStyle = .round
color(0xFFFFFF, 0.75).setStroke(); shine.stroke()
ctx.restoreGState()

// Anneau de la loupe
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.3).cgColor)
glass.lineWidth = 46
color(0xF4F6FB).setStroke()
glass.stroke()
ctx.restoreGState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icone.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
