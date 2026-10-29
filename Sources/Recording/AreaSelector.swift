import AppKit

// Dims every screen and lets the user drag out a rectangle, which is used as soon as they let go. Reports the screen
// and the rectangle in that screen's coordinates (points, bottom-left origin), or nil if they press Esc. Moving and
// resizing it afterwards is AreaEditor's job.
@MainActor
final class AreaSelector {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        var onBegin: (() -> Void)?
        var onConfirm: ((CGRect) -> Void)?
        private var selection: CGRect?
        private var origin: CGPoint?

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func clear() {
            selection = nil
            origin = nil
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            onBegin?()
            window?.makeKey()
            origin = convert(event.locationInWindow, from: nil)
            selection = nil
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let point = convert(event.locationInWindow, from: nil)
            let rect = CGRect(
                x: min(origin.x, point.x), y: min(origin.y, point.y),
                width: abs(point.x - origin.x), height: abs(point.y - origin.y)
            )
            selection = rect.intersection(bounds).integral
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            origin = nil
            if let selection, selection.width >= AreaGeometry.minimumSize, selection.height >= AreaGeometry.minimumSize {
                onConfirm?(selection)
            } else {
                clear()
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            guard let selection else {
                let hint = "Drag to select the area to record. Press Esc to cancel." as NSString
                let size = hint.size(withAttributes: attributes)
                hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
                return
            }
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5)).stroke()
            let label = "\(Int(selection.width))×\(Int(selection.height))" as NSString
            let size = label.size(withAttributes: attributes)
            let above = selection.maxY + 8
            label.draw(at: CGPoint(x: selection.minX, y: above + size.height < bounds.maxY ? above : selection.maxY - size.height - 8), withAttributes: attributes)
        }
    }

    private var overlays: [(screen: NSScreen, window: OverlayWindow, view: SelectionView)] = []
    private var keyMonitor: Any?
    private let completion: ((screen: NSScreen, rect: CGRect)?) -> Void

    init(completion: @escaping ((screen: NSScreen, rect: CGRect)?) -> Void) {
        self.completion = completion
        NSApp.activate()
        NSCursor.crosshair.set()
        // Esc cancels whichever overlay is key, or none if activation hasn't landed yet.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.finish(nil) }
            return nil
        }
        let mouse = NSEvent.mouseLocation
        let keyScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onBegin = { [weak self, weak view] in self?.clearSelections(except: view) }
            view.onConfirm = { [weak self] rect in self?.finish((screen, rect)) }
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            if screen == keyScreen {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
            } else {
                window.orderFrontRegardless()
            }
            overlays.append((screen, window, view))
        }
    }

    private func clearSelections(except keep: SelectionView?) {
        for overlay in overlays where overlay.view !== keep {
            overlay.view.clear()
        }
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ result: (screen: NSScreen, rect: CGRect)?) {
        guard !overlays.isEmpty else { return }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        overlays.forEach { $0.window.orderOut(nil) }
        overlays = []
        NSCursor.arrow.set()
        completion(result)
    }
}
