import AppKit
import ScreenCaptureKit

struct CaptureTarget: Identifiable {
    enum Kind {
        case display(SCDisplay)
        case window(SCWindow)
    }

    let id: String
    let kind: Kind
    let title: String
    let phrase: String
    let subtitle: String
    let icon: NSImage?
    let offScreenReason: String?
    var thumbnail: CGImage?

    init(display: SCDisplay, number: Int, of count: Int) {
        id = "display-\(display.displayID)"
        kind = .display(display)
        let name = NSScreen.screens.first { $0.displayID == display.displayID }?.localizedName ?? "Display \(number)"
        title = count == 1 ? "Entire Screen" : name
        phrase = count == 1 ? "the entire screen" : name
        subtitle = "\(Int(display.frame.width))×\(Int(display.frame.height))"
        icon = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        offScreenReason = nil
    }

    init(window: SCWindow) {
        let app = window.owningApplication
        id = "window-\(window.windowID)"
        kind = .window(window)
        title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? app?.applicationName ?? "Window"
        phrase = "“\(title)”"
        subtitle = app?.applicationName ?? ""
        let running = app.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
        icon = running?.icon
        offScreenReason = window.isOnScreen ? nil : running?.isHidden == true ? "App is hidden" : "Minimized or on another desktop"
    }

    var isDisplay: Bool {
        if case .display = kind { true } else { false }
    }

    func filter(excluding ours: [SCRunningApplication]) -> SCContentFilter {
        switch kind {
        case let .display(display):
            SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        case let .window(window):
            SCContentFilter(desktopIndependentWindow: window)
        }
    }

    func captureThumbnail(excluding ours: [SCRunningApplication]) async -> CGImage? {
        guard offScreenReason == nil else { return nil }
        let frame = switch kind {
        case let .display(display): display.frame
        case let .window(window): window.frame
        }
        let scale = 480 / max(frame.width, frame.height, 1)
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(frame.width * scale))
        configuration.height = max(2, Int(frame.height * scale))
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter(excluding: ours), configuration: configuration)
    }
}

// The real ScreenCaptureKit behind the recording flow.
@MainActor
final class LiveCaptureSource: CaptureSource {
    private var ourApps: [SCRunningApplication] = []
    private var displays: [SCDisplay] = []
    private var prepared: SCContentFilter?
    private var recorder: Recorder?

    var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    func askForPermission() {
        CGRequestScreenCaptureAccess()
    }

    private func fetchContent() async -> SCShareableContent? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            return nil
        }
        ourApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        displays = content.displays
        return content
    }

    func targets() async -> [CaptureTarget]? {
        guard let content = await fetchContent() else { return nil }
        let bundleID = Bundle.main.bundleIdentifier
        let displays = content.displays.enumerated().map { index, display in
            CaptureTarget(display: display, number: index + 1, of: content.displays.count)
        }
        let windows = content.windows
            .filter { window in
                guard window.windowLayer == 0, window.frame.width >= 120, window.frame.height >= 80,
                      let app = window.owningApplication, app.bundleIdentifier != bundleID else { return false }
                if window.isOnScreen {
                    return true
                }
                // Off-screen windows include plenty of invisible helpers; keep titled windows of regular apps.
                guard let title = window.title, !title.isEmpty else { return false }
                return NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular
            }
            .map(CaptureTarget.init(window:))
            .sorted { ($0.subtitle.lowercased(), $0.title) < ($1.subtitle.lowercased(), $1.title) }
        return displays + windows
    }

    func loadThumbnails(for targets: [CaptureTarget], each: @escaping (String, CGImage?) -> Void) async {
        let ours = ourApps
        await withTaskGroup(of: (String, CGImage?).self) { group in
            for target in targets {
                group.addTask { (target.id, await target.captureThumbnail(excluding: ours)) }
            }
            for await (id, image) in group {
                each(id, image)
            }
        }
    }

    func prepare(_ target: CaptureTarget) {
        prepared = target.filter(excluding: ourApps)
    }

    func prepare(display id: CGDirectDisplayID) -> Bool {
        guard let display = displays.first(where: { $0.displayID == id }) else { return false }
        prepared = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])
        return true
    }

    func find(_ target: LastTarget) async -> Bool? {
        guard let content = await fetchContent() else { return nil }
        switch target {
        case let .window(id, _, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return false }
            prepared = SCContentFilter(desktopIndependentWindow: window)
        case let .display(id, _), let .area(id, _, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return false }
            prepared = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])
        }
        return true
    }

    var isPrepared: Bool { prepared != nil }

    func refresh(window id: CGWindowID) async {
        if let window = await fetchContent()?.windows.first(where: { $0.windowID == id }) {
            prepared = SCContentFilter(desktopIndependentWindow: window)
        }
    }

    func record(area: CGRect?, microphone: Bool, into folder: URL, events: @escaping @MainActor (Recorder.Event) -> Void) {
        guard let prepared else { return }
        makeRecorder(microphone: microphone, folder: folder, events: events).record(prepared, area: area)
    }

    func pick(microphone: Bool, into folder: URL, events: @escaping @MainActor (Recorder.Event) -> Void) {
        makeRecorder(microphone: microphone, folder: folder, events: events).pick()
    }

    private func makeRecorder(microphone: Bool, folder: URL, events: @escaping @MainActor (Recorder.Event) -> Void) -> Recorder {
        let recorder = Recorder(folder: folder, microphone: microphone) { event in
            Task { @MainActor in events(event) }
        }
        self.recorder = recorder
        return recorder
    }

    func stop() {
        recorder?.stop()
    }

    func cancel() {
        recorder?.cancel()
    }

    func fit(windowSize: CGSize) {
        recorder?.fit(windowSize: windowSize)
    }

    func forget() {
        prepared = nil
        recorder = nil
    }
}
