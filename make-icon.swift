import AppKit

let side = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(srgbRed: 0.36, green: 0.40, blue: 0.98, alpha: 1),
    ending: NSColor(srgbRed: 0.60, green: 0.27, blue: 0.88, alpha: 1)
)!.draw(in: body, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let size = symbol.size
    symbol.draw(in: NSRect(x: (Double(side) - size.width) / 2, y: (Double(side) - size.height) / 2, width: size.width, height: size.height))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
