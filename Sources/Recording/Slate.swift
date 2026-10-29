import AppKit

// A big 3-2-1 in the middle of the screen being recorded, so it's obvious when recording begins.
@MainActor
final class CountdownOverlay {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")

    init(on screen: NSScreen) {
        let size: CGFloat = 200
        window = NSWindow(
            contentRect: NSRect(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2, width: size, height: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.canHide = false
        window.sharingType = .none

        let background = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        background.layer?.cornerRadius = 40
        label.font = .systemFont(ofSize: 120, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        background.addSubview(label)
        window.contentView = background
        window.orderFrontRegardless()
    }

    func show(_ number: Int) {
        label.stringValue = "\(number)"
        label.sizeToFit()
        let bounds = window.contentView?.bounds ?? .zero
        label.frame = NSRect(x: 0, y: (bounds.height - label.frame.height) / 2, width: bounds.width, height: label.frame.height)
    }

    func remove() {
        window.orderOut(nil)
    }
}

// A flat clapperboard. Its stick starts open and snaps shut on clap(after:).
final class ClapperView: NSView {
    private static let openAngle = 0.4
    private let stick: CALayer

    init(color: NSColor, stripes: NSColor) {
        stick = Self.board(CGRect(x: 0, y: 39, width: 60, height: 11), radius: 3, band: 2.5...8.5, slant: -5, color: color, stripes: stripes)
        super.init(frame: CGRect(x: 0, y: 0, width: 60, height: 54))
        wantsLayer = true
        layer?.addSublayer(Self.board(CGRect(x: 0, y: 0, width: 60, height: 36), radius: 5, band: 26...33, slant: 5, color: color, stripes: stripes))
        stick.anchorPoint = .zero
        stick.position = CGPoint(x: 0, y: 39)
        layer?.addSublayer(stick)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { frame.size }

    func open() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stick.setAffineTransform(CGAffineTransform(rotationAngle: Self.openAngle))
        CATransaction.commit()
    }

    func clap() {
        let close = CABasicAnimation(keyPath: "transform.rotation.z")
        close.fromValue = Self.openAngle
        close.toValue = 0
        close.duration = 0.12
        close.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stick.setAffineTransform(.identity)
        CATransaction.commit()
        stick.add(close, forKey: nil)
    }

    private static func board(_ rect: CGRect, radius: CGFloat, band: ClosedRange<CGFloat>, slant: CGFloat, color: NSColor, stripes: NSColor) -> CALayer {
        let board = CAShapeLayer()
        board.frame = rect
        board.path = CGPath(roundedRect: board.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        board.fillColor = color.cgColor
        let path = CGMutablePath()
        for x in stride(from: 7.0, to: rect.width - 12, by: 14) {
            path.addLines(between: [
                CGPoint(x: x, y: band.lowerBound), CGPoint(x: x + 8, y: band.lowerBound),
                CGPoint(x: x + 8 + slant, y: band.upperBound), CGPoint(x: x + slant, y: band.upperBound),
            ])
            path.closeSubpath()
        }
        let paint = CAShapeLayer()
        paint.frame = board.bounds
        paint.path = path
        paint.fillColor = stripes.cgColor
        board.addSublayer(paint)
        return board
    }
}

// A brief system-style HUD over what's being recorded when recording starts: a faint dim and a glass panel with a
// clapperboard that snaps shut, fading in and out like macOS's own HUDs. Like the other overlays it's left out of the
// recording.
@MainActor
final class Slate {
    private let window: NSWindow
    private let clapper = ClapperView(color: .white, stripes: NSColor(white: 0.22, alpha: 1))
    private let shownAt = CACurrentMediaTime()
    private var dismissed = false

    // Shows at once, with the stick open; clap() snaps it shut when recording actually begins, a moment later.
    init(over target: CGRect, clipNumber: Int) {
        let hudSize = CGSize(width: 180, height: 150)
        // Big enough for the panel even when the target is a small area.
        let frame = target.insetBy(
            dx: -max(0, (hudSize.width + 40 - target.width) / 2),
            dy: -max(0, (hudSize.height + 40 - target.height) / 2)
        )
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.canHide = false
        window.sharingType = .none
        window.alphaValue = 0

        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let dim = NSView(frame: target.offsetBy(dx: -frame.minX, dy: -frame.minY))
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        root.addSubview(dim)

        let title = NSTextField(labelWithString: "Recording")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        let subtitle = NSTextField(labelWithString: "Clip \(clipNumber)")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [clapper, title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(12, after: clapper)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: CGRect(origin: .zero, size: hudSize))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        let hudFrame = CGRect(
            x: (frame.width - hudSize.width) / 2, y: (frame.height - hudSize.height) / 2,
            width: hudSize.width, height: hudSize.height
        )
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: hudFrame)
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.cornerRadius = 26
            glass.tintColor = NSColor.black.withAlphaComponent(0.35)
            glass.contentView = content
            root.addSubview(glass)
        } else {
            let hud = NSVisualEffectView(frame: hudFrame)
            hud.material = .hudWindow
            hud.blendingMode = .behindWindow
            hud.state = .active
            hud.appearance = NSAppearance(named: .vibrantDark)
            hud.wantsLayer = true
            hud.layer?.cornerRadius = 22
            hud.layer?.masksToBounds = true
            hud.addSubview(content)
            root.addSubview(hud)
        }
        window.contentView = root
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clapper.open()
        }
        // In case recording never starts and nobody says so.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.dismiss()
        }
    }

    // Waits for the fade-in to finish, so the snap is seen.
    func clap() {
        let wait = max(0, shownAt + 0.2 - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                clapper.clap()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                dismiss()
            }
        }
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            window.orderOut(nil)
        })
    }
}
