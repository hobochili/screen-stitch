import AppKit

// Three video clips stacked like a timeline and stitched together, with a record badge.

let side = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let stitchRed = color(0xFF4B55)

let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: color(0x4B3FE0), ending: color(0x1E1659))!.draw(in: body, angle: -90)
NSGraphicsContext.saveGraphicsState()
body.addClip()
NSGradient(starting: color(0xFFFFFF, 0.16), ending: color(0xFFFFFF, 0))!
    .draw(in: NSRect(x: 100, y: 620, width: 824, height: 304), angle: -90)
NSGraphicsContext.restoreGraphicsState()

let cardSize = NSSize(width: 560, height: 176)
let gap: CGFloat = 50
let stagger: [CGFloat] = [-30, 0, 30]
let tints = [(0x64D2FF, 0x0A84FF), (0xDA8FFF, 0xAF52DE), (0x7BE495, 0x30B34E)]
let bottom = 500 - (3 * cardSize.height + 2 * gap) / 2
var cards: [NSRect] = []

for index in 0..<3 {
    let y = bottom + CGFloat(2 - index) * (cardSize.height + gap)
    let card = NSRect(x: 512 - cardSize.width / 2 + stagger[index], y: y, width: cardSize.width, height: cardSize.height)
    cards.append(card)
    let shape = NSBezierPath(roundedRect: card, xRadius: 34, yRadius: 34)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 26
    shadow.set()
    color(tints[index].1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(tints[index].0), ending: color(tints[index].1))!.draw(in: shape, angle: -90)
    color(0xFFFFFF, 0.55).setStroke()
    shape.lineWidth = 6
    shape.stroke()

    let play = NSBezierPath()
    play.move(to: NSPoint(x: card.midX - 26, y: card.midY + 36))
    play.line(to: NSPoint(x: card.midX + 38, y: card.midY))
    play.line(to: NSPoint(x: card.midX - 26, y: card.midY - 36))
    play.close()
    play.lineJoinStyle = .round
    play.lineWidth = 10
    color(0xFFFFFF, 0.9).setFill()
    color(0xFFFFFF, 0.9).setStroke()
    play.fill()
    play.stroke()
}

// Stitches across the gaps, reaching a little into each card like a seam.
for index in 0..<2 {
    let upper = cards[index], lower = cards[index + 1]
    let top = upper.minY + 26, bottomY = lower.maxY - 26
    let left = max(upper.minX, lower.minX) + 60, right = min(upper.maxX, lower.maxX) - 60
    for step in 0..<6 {
        let x = left + (right - left) * CGFloat(step) / 5
        let stitch = NSBezierPath()
        stitch.move(to: NSPoint(x: x, y: top))
        stitch.line(to: NSPoint(x: x, y: bottomY))
        stitch.lineWidth = 14
        stitch.lineCapStyle = .round
        stitchRed.setStroke()
        stitch.stroke()
    }
}

let dot = NSRect(x: cards[0].maxX - 70, y: cards[0].maxY - 58, width: 116, height: 116)
color(0xFFFFFF).setFill()
NSBezierPath(ovalIn: dot).fill()
stitchRed.setFill()
NSBezierPath(ovalIn: dot.insetBy(dx: 14, dy: 14)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
