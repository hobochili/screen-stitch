import AppKit

// Private but long-standing; the public accessibility API has no way to match a window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func axWindowID(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

// Marks what will be recorded: a dashed outline while ready, a red frame while recording. Around an area or a window
// it's drawn just outside what's captured; for a display it's drawn just inside the edges, where this app's windows
// are excluded from the recording. A window's frame follows the window and hides while it's off screen.
@MainActor
final class TargetFrame {
    enum Target {
        case area(CGRect)
        case display(CGRect)
        case window(CGWindowID)
    }

    private final class FrameView: NSView {
        var recording = false {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2.5, dy: 2.5))
            if recording {
                path.lineWidth = 5
                NSColor.systemRed.setStroke()
                path.stroke()
                return
            }
            path.lineWidth = 3
            NSColor.black.withAlphaComponent(0.45).setStroke()
            path.stroke()
            path.lineWidth = 1.5
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            path.stroke()
        }
    }

    private let window: NSWindow
    private let view = FrameView()
    private let target: Target
    enum Visibility {
        case visible
        case covered
        case offScreen
    }

    private var tracker: Timer?
    private var windowSize: CGSize?
    private var visibility: Visibility?
    private var ticks = 0

    var recording = false {
        didSet { view.recording = recording }
    }

    var onResize: ((CGSize) -> Void)?
    var onVisibilityChange: ((Visibility) -> Void)?
    // A window moved, resized, or went off screen or came back.
    var onMove: (() -> Void)?
    private(set) var windowBounds: CGRect?

    init(_ target: Target) {
        self.target = target
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.canHide = false
        window.sharingType = .none
        window.contentView = view
        update()
        if case .window = target {
            tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    private func update() {
        let frame: CGRect?
        switch target {
        case let .area(rect):
            frame = rect.insetBy(dx: -6, dy: -6)
        case let .display(rect):
            frame = rect
        case let .window(id):
            let bounds = Self.frame(ofWindow: id)
            if let size = bounds?.size, size != windowSize {
                if windowSize != nil { onResize?(size) }
                windowSize = size
            }
            if bounds != windowBounds {
                windowBounds = bounds
                onMove?()
            }
            frame = bounds?.insetBy(dx: -6, dy: -6)
            ticks += 1
            if bounds == nil || visibility == nil || ticks % 10 == 0 {
                let current: Visibility = bounds == nil ? .offScreen : Self.isCovered(window: id) ? .covered : .visible
                if current != visibility {
                    visibility = current
                    onVisibilityChange?(current)
                }
            }
        }
        guard let frame else {
            window.orderOut(nil)
            return
        }
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    // Needs Accessibility permission. Restores the window if it's minimized, then brings it and its app to the front.
    @discardableResult
    static func raise(window id: CGWindowID, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let window = (windows as? [AXUIElement])?.first(where: { element in
                  var windowID: CGWindowID = 0
                  return axWindowID(element, &windowID) == .success && windowID == id
              }) else { return false }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return true
    }

    // True when another app's window, or another window of the same app, overlaps a fifth or more of it.
    // `ignoring` leaves out another app's windows, such as the window's own app.
    static func isCovered(window id: CGWindowID, ignoring app: pid_t? = nil) -> Bool {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary),
              let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], id) as? [[String: Any]] else { return false }
        let ours = ProcessInfo.processInfo.processIdentifier
        return above.contains { info in
            let owner = info[kCGWindowOwnerPID as String] as? pid_t
            guard info[kCGWindowLayer as String] as? Int == 0, owner != ours, owner != app,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let other = CGRect(dictionaryRepresentation: dictionary) else { return false }
            let overlap = other.intersection(bounds)
            return !overlap.isNull && overlap.width * overlap.height >= bounds.width * bounds.height / 5
        }
    }

    // In AppKit coordinates, or nil while the window is minimized, hidden or on another desktop.
    static func frame(ofWindow id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    func remove() {
        tracker?.invalidate()
        tracker = nil
        window.orderOut(nil)
    }
}
