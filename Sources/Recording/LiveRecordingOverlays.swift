import AppKit
import os

// The real windows and panels behind the recording flow.
@MainActor
final class LiveRecordingOverlays: RecordingOverlays {
    static let log = Logger(subsystem: "local.screen-stitch", category: "focus")

    private weak var model: StitchModel?
    private var controls: RecordingControls?
    private var targetFrame: TargetFrame?
    private var areaSelector: AreaSelector?
    private var areaEditor: AreaEditor?
    private var pill: TargetPill?
    private var slate: Slate?

    init(model: StitchModel) {
        self.model = model
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" }
    }

    func hideApp(handingFocusTo pid: pid_t?, window: CGWindowID?) {
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        if let app {
            NSApp.yieldActivation(to: app)
        }
        NSApp.hide(nil)
        if let app {
            Self.bringForward(app, window: window)
        }
        // Activating an app reorders its windows, so the one picked is raised once the app is in front.
        if let window, let pid {
            let trusted = AXIsProcessTrusted()
            Self.log.notice("Accessibility \(trusted ? "allowed" : "not allowed", privacy: .public)")
            if trusted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let raised = TargetFrame.raise(window: window, pid: pid)
                    Self.log.notice("Raised the picked window: \(raised, privacy: .public)")
                }
            }
        }
    }

    // macOS refuses the usual hand-off when Screen Stitch isn't the active app (a shortcut pressed in another app), and
    // a background-style app like Problem Reporter can become active without its window coming forward. Opening the
    // app, as a Dock click does, works in both cases. It can also open a new window in some apps, so it's only the
    // fallback, when the app isn't active or another app's window still covers the picked one.
    static func bringForward(_ app: NSRunningApplication, window: CGWindowID? = nil) {
        app.activate(from: .current, options: [.activateAllWindows])
        // Background-style apps report being active even when their window stays behind, so they're always opened. A
        // second look catches a window that came forward and then fell back.
        for (delay, first) in [(0.3, true), (1.2, false)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let covered = window.map { TargetFrame.isCovered(window: $0, ignoring: app.processIdentifier) } ?? false
                let background = app.activationPolicy == .accessory
                let name = app.localizedName ?? "app"
                log.notice("Bringing \(name, privacy: .public) forward after \(delay, privacy: .public)s: active \(app.isActive, privacy: .public), covered by another app \(covered, privacy: .public), background-style \(background, privacy: .public)")
                guard !app.isActive || covered || (first && background), let url = app.bundleURL else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
        }
    }

    func showApp() {
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hideMainWindow() {
        mainWindow?.orderOut(nil)
    }

    // Unhides the app and sends it the reopen event a Dock click sends, which restores a minimized window when the
    // app has no other windows open. Anything else is up to the user, and the floating bar says so.
    func restore(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.unhide()
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    var isAccessibilityAllowed: Bool { AXIsProcessTrusted() }

    func askForAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func raise(window: CGWindowID, pid: pid_t) {
        TargetFrame.raise(window: window, pid: pid)
    }

    func setRecordingBadge(_ on: Bool) {
        NSApp.dockTile.badgeLabel = on ? "REC" : nil
    }

    func frame(ofWindow id: CGWindowID) -> CGRect? {
        TargetFrame.frame(ofWindow: id)
    }

    // The display what's being recorded is on: the floating bar goes there.
    private func screen(near target: LastTarget?) -> NSScreen? {
        switch target {
        case let .display(id, _)?, let .area(id, _, _)?:
            return NSScreen.screens.first { $0.displayID == id }
        case let .window(id, _, _)?:
            guard let frame = TargetFrame.frame(ofWindow: id) else { return NSScreen.main }
            return NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.main
        case nil:
            return NSScreen.main
        }
    }

    func showBar(near target: LastTarget?) {
        guard let model else { return }
        controls?.remove()
        controls = RecordingControls(model: model, on: target.flatMap { screen(near: $0) })
    }

    func refreshBar() {
        DispatchQueue.main.async { [weak self] in self?.controls?.refresh() }
    }

    func removeBar() {
        controls?.remove()
        controls = nil
    }

    func showFrame(around target: LastTarget, onMove: @escaping () -> Void, onResize: @escaping (CGSize) -> Void,
                   onVisibilityChange: @escaping (TargetFrame.Visibility) -> Void) {
        targetFrame?.remove()
        switch target {
        case let .window(id, _, _):
            let frame = TargetFrame(.window(id))
            frame.onVisibilityChange = onVisibilityChange
            frame.onMove = onMove
            frame.onResize = onResize
            targetFrame = frame
        case let .display(id, _):
            targetFrame = NSScreen.screens.first { $0.displayID == id }.map { TargetFrame(.display($0.frame)) }
        case let .area(_, _, onScreen):
            targetFrame = TargetFrame(.area(onScreen))
        }
    }

    func markFrameRecording() {
        targetFrame?.recording = true
    }

    func removeFrame() {
        targetFrame?.remove()
        targetFrame = nil
    }

    func selectArea(done: @escaping ((display: CGDirectDisplayID, screen: CGRect, rect: CGRect)?) -> Void) {
        areaSelector = AreaSelector { [weak self] result in
            MainActor.assumeIsolated {
                self?.areaSelector = nil
                done(result.flatMap { result in
                    result.screen.displayID.map { (display: $0, screen: result.screen.frame, rect: result.rect) }
                })
            }
        }
    }

    func cancelAreaSelection() {
        areaSelector?.cancel()
    }

    func editArea(_ onScreen: CGRect, on display: CGDirectDisplayID, onChange: @escaping (CGRect, CGRect) -> Void,
                  onStart: @escaping () -> Void) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return }
        areaEditor?.remove()
        areaEditor = AreaEditor(rect: onScreen, within: screen.frame, onChange: { rect in
            onChange(rect, screen.frame)
        }, onStart: onStart)
    }

    func removeAreaEditor() {
        areaEditor?.remove()
        areaEditor = nil
    }

    // Below a window, inside its screen's visible area, or nowhere if it fills it; below an area, or just inside it.
    func showPill(_ mode: TargetPill.Mode, by target: LastTarget, start: @escaping () -> Void, stop: @escaping () -> Void) {
        var place: (target: CGRect, screen: CGRect, insideIfNeeded: Bool)?
        switch target {
        case .window:
            if let frame = targetFrame?.windowBounds,
               let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
                place = (frame, screen.visibleFrame, false)
            }
        case let .area(id, _, onScreen):
            if let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
                place = (onScreen, screen.frame, true)
            }
        case .display:
            break
        }
        guard let place else {
            pill?.hide()
            return
        }
        if pill == nil {
            pill = TargetPill(start: start, stop: stop)
        }
        pill?.show(mode, below: place.target, within: place.screen, insideIfNeeded: place.insideIfNeeded)
    }

    func hidePill() {
        pill?.hide()
    }

    func showSlate(over target: LastTarget, clipNumber: Int) {
        let rect: CGRect? = switch target {
        case let .window(id, _, _): TargetFrame.frame(ofWindow: id)
        case let .display(id, _): NSScreen.screens.first { $0.displayID == id }?.frame
        case let .area(_, _, onScreen): onScreen
        }
        guard let rect else { return }
        slate = Slate(over: rect, clipNumber: clipNumber)
    }

    func clapSlate() {
        slate?.clap()
        slate = nil
    }

    func dismissSlate() {
        slate?.dismiss()
        slate = nil
    }
}
