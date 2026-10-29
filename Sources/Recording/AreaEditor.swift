import AppKit

// Moving and resizing an area by dragging inside it or by an edge or corner. Points, bottom-left origin.
enum AreaGeometry {
    enum Handle {
        case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    }

    static let minimumSize: CGFloat = 40

    // An edge or corner within `slop` of the area's outline, the inside, or nil outside it.
    static func handle(at point: CGPoint, in rect: CGRect, slop: CGFloat = 8) -> Handle? {
        let left = abs(point.x - rect.minX) <= slop, right = abs(point.x - rect.maxX) <= slop
        let bottom = abs(point.y - rect.minY) <= slop, top = abs(point.y - rect.maxY) <= slop
        let alongX = point.x >= rect.minX - slop && point.x <= rect.maxX + slop
        let alongY = point.y >= rect.minY - slop && point.y <= rect.maxY + slop
        guard alongX, alongY else { return nil }
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }
        if left { return .left }
        if right { return .right }
        if top { return .top }
        if bottom { return .bottom }
        return rect.contains(point) ? .move : nil
    }

    // The area after dragging `handle` by `delta`. A moved area keeps its size; a resized one keeps its opposite edges.
    // Either way it stays inside `bounds` and no smaller than the minimum.
    static func adjusted(_ rect: CGRect, by delta: CGSize, handle: Handle, within bounds: CGRect) -> CGRect {
        if handle == .move {
            var moved = rect.offsetBy(dx: delta.width, dy: delta.height)
            moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
            moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
            return moved.integral
        }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if [.left, .topLeft, .bottomLeft].contains(handle) {
            minX = min(max(minX + delta.width, bounds.minX), maxX - minimumSize)
        }
        if [.right, .topRight, .bottomRight].contains(handle) {
            maxX = max(min(maxX + delta.width, bounds.maxX), minX + minimumSize)
        }
        if [.bottom, .bottomLeft, .bottomRight].contains(handle) {
            minY = min(max(minY + delta.height, bounds.minY), maxY - minimumSize)
        }
        if [.top, .topLeft, .topRight].contains(handle) {
            maxY = max(min(maxY + delta.height, bounds.maxY), minY + minimumSize)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
    }
}

// macOS lets only the active app set the pointer, and Screen Stitch stays in the background while an area is set up.
// This private but long-standing switch lets it show the move and resize pointers anyway.
@_silgen_name("_CGSDefaultConnection")
private func cgsDefaultConnection() -> Int32

@_silgen_name("CGSSetConnectionProperty")
private func cgsSetConnectionProperty(_ connection: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

// The area while getting ready: drag inside it to move it, or an edge or corner to resize it, and Start next to it.
// It sits above other windows, so a click inside the area moves it rather than reaching the app below; outside the
// area, apps work as usual. Panels that never activate the app, so the hidden main window stays hidden.
@MainActor
final class AreaEditor {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
    }

    // The outline and handles. The panel is filled nearly clear, not clear: macOS sends clicks on fully clear pixels
    // to the window underneath, so drags would never arrive.
    private final class EditorView: NSView {
        weak var editor: AreaEditor?
        private var drag: (handle: AreaGeometry.Handle, start: CGPoint, original: CGRect)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func point(_ event: NSEvent) -> CGPoint {
            window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        }

        private func handle(_ event: NSEvent) -> AreaGeometry.Handle? {
            editor.flatMap { AreaGeometry.handle(at: point(event), in: $0.rect) }
        }

        override func mouseMoved(with event: NSEvent) {
            Self.cursor(for: handle(event)).set()
        }

        override func mouseExited(with event: NSEvent) {
            if drag == nil {
                NSCursor.arrow.set()
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let editor, let handle = handle(event) else { return }
            drag = (handle, point(event), editor.rect)
            if handle == .move {
                NSCursor.closedHand.set()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let editor, let drag else { return }
            let point = point(event)
            let delta = CGSize(width: point.x - drag.start.x, height: point.y - drag.start.y)
            editor.rect = AreaGeometry.adjusted(drag.original, by: delta, handle: drag.handle, within: editor.bounds)
        }

        override func mouseUp(with event: NSEvent) {
            guard drag != nil else { return }
            drag = nil
            editor?.finishEditing()
            Self.cursor(for: handle(event)).set()
        }

        private static func cursor(for handle: AreaGeometry.Handle?) -> NSCursor {
            switch handle {
            case .move: .openHand
            case .left: .frameResize(position: .left, directions: .all)
            case .right: .frameResize(position: .right, directions: .all)
            case .top: .frameResize(position: .top, directions: .all)
            case .bottom: .frameResize(position: .bottom, directions: .all)
            case .topLeft: .frameResize(position: .topLeft, directions: .all)
            case .topRight: .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
            case nil: .arrow
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let editor, let window else { return }
            NSColor.black.withAlphaComponent(0.01).setFill()
            bounds.fill()
            let area = editor.rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            // The same dashed outline as the other targets, just outside the area so it never covers what's recorded.
            let outline = area.insetBy(dx: -3.5, dy: -3.5)
            let path = NSBezierPath(rect: outline)
            path.lineWidth = 3
            NSColor.black.withAlphaComponent(0.45).setStroke()
            path.stroke()
            path.lineWidth = 1.5
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            path.stroke()
            for point in [
                CGPoint(x: outline.minX, y: outline.minY), CGPoint(x: outline.midX, y: outline.minY),
                CGPoint(x: outline.maxX, y: outline.minY), CGPoint(x: outline.minX, y: outline.midY),
                CGPoint(x: outline.maxX, y: outline.midY), CGPoint(x: outline.minX, y: outline.maxY),
                CGPoint(x: outline.midX, y: outline.maxY), CGPoint(x: outline.maxX, y: outline.maxY),
            ] {
                let knob = NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                NSColor.white.setFill()
                knob.fill()
                NSColor.black.withAlphaComponent(0.45).setStroke()
                knob.lineWidth = 1
                knob.stroke()
            }
        }
    }

    // Room around the area for grabbing its edges.
    private static let margin: CGFloat = 12

    let bounds: CGRect
    var rect: CGRect {
        didSet { layout() }
    }

    private let onChange: (CGRect) -> Void
    private let onStart: () -> Void
    private let panel: Panel
    private let view = EditorView()
    private let pill: TargetPill

    // `rect` and `bounds` (the display it's on) are in screen coordinates. onChange gets the area after each drag.
    init(rect: CGRect, within bounds: CGRect, onChange: @escaping (CGRect) -> Void, onStart: @escaping () -> Void) {
        self.rect = rect
        self.bounds = bounds
        self.onChange = onChange
        self.onStart = onStart
        panel = Self.makePanel()
        pill = TargetPill(start: onStart, stop: {})
        view.editor = self
        panel.contentView = view
        let connection = cgsDefaultConnection()
        _ = cgsSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        panel.orderFrontRegardless()
        layout()
    }

    private static func makePanel() -> Panel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.canHide = false
        panel.sharingType = .none
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    // The size and Start go below the area, or just inside its bottom edge when the screen ends there.
    private func layout() {
        panel.setFrame(rect.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
        view.needsDisplay = true
        pill.show(.ready(size: rect.size), below: rect, within: bounds, insideIfNeeded: true)
    }

    fileprivate func finishEditing() {
        onChange(rect)
    }

    func remove() {
        panel.orderOut(nil)
        pill.hide()
    }
}
