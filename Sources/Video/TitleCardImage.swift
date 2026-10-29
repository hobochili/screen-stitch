import AppKit

// Draws a title card at the video's size: centered text in New York, Apple's serif, white on black or black on white.
enum TitleCardImage {
    static func png(_ card: TitleCard, width: Int, height: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let canvas = NSRect(x: 0, y: 0, width: width, height: height)
        (card.isLight ? NSColor.white : NSColor.black).setFill()
        canvas.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let size = CGFloat(min(width, height)) * 0.09
        let system = NSFont.systemFont(ofSize: size, weight: .medium)
        let font = system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: card.isLight ? NSColor.black : NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let text = card.text as NSString
        let box = canvas.insetBy(dx: canvas.width * 0.1, dy: canvas.height * 0.1)
        let measured = text.boundingRect(with: box.size, options: [.usesLineFragmentOrigin], attributes: attributes)
        let rect = NSRect(x: box.minX, y: (canvas.height - measured.height) / 2, width: box.width, height: measured.height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
