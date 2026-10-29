import AVFoundation
import Carbon.HIToolbox
import os
import Quartz
import ScreenCaptureKit
import SwiftUI

enum RecordingState: Equatable {
    case idle
    case picking
    case needsPermission
    case systemPicker
    case selectingArea
    case ready(String)
    case countdown(Int)
    case starting
    case recording(since: Date)
}

// What was last recorded, so Record can offer it again. Areas keep their display-relative rect for capture
// and their global rect for the frame drawn around them.
enum LastTarget {
    case window(id: CGWindowID, pid: pid_t, title: String)
    case display(id: CGDirectDisplayID, phrase: String)
    case area(display: CGDirectDisplayID, rect: CGRect, onScreen: CGRect)

    // How the target reads in a sentence, e.g. "Ready to record the entire screen".
    var phrase: String {
        switch self {
        case let .window(_, _, title): "“\(title)”"
        case let .display(_, phrase): phrase
        case let .area(_, rect, _): "the \(Int(rect.width))×\(Int(rect.height)) area"
        }
    }
}

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
        title = count == 1 ? "Entire Screen" : "Display \(number)"
        phrase = count == 1 ? "the entire screen" : "Display \(number)"
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

enum EncodeState: Equatable {
    case idle
    case encoding
    case done(output: URL, outputBytes: Int64, inputBytes: Int64)
    case failed(String)
}

@MainActor
@Observable
final class StitchModel {
    // Where settings are kept. Tests point this at a throwaway domain.
    nonisolated(unsafe) static var defaults = UserDefaults.standard
    let tools = Tools.locate()
    // The session is the list of clips and title cards, and the video made from them. The last target only matters
    // while recording a series, so a session without clips forgets it.
    var items: [SessionItem] = [] {
        didSet {
            if clips.isEmpty {
                lastTarget = nil
            }
            selection.formIntersection(items.map(\.id))
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }
    }
    var clips: [Clip] { items.compactMap(\.clip) }
    var titleCards: [TitleCard] { items.compactMap(\.card) }
    // Recordings made or picked up during the session, as opposed to videos added from elsewhere, and every video
    // combined from it. Clear Session can move these to the Trash.
    @ObservationIgnored var sessionRecordings: Set<URL> = []
    @ObservationIgnored var sessionOutputs: [URL] = []
    @ObservationIgnored var moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var selection: Set<UUID> = [] {
        didSet {
            quickLookOutput = nil
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }
    }
    var outputSize: OutputSize = .p1080
    var quality: Quality = .standard
    var state: EncodeState = .idle {
        didSet {
            if case .done = state {
                return
            }
            outputThumbnail = nil
            if quickLookOutput != nil {
                quickLookOutput = nil
                if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                    QLPreviewPanel.shared().reloadData()
                }
            }
        }
    }
    var progress = 0.0
    var notice: String? {
        didSet {
            guard let notice else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.notice == notice { self?.notice = nil }
            }
        }
    }
    var warning: String?
    var isDropTargeted = false
    var watchFolder: URL?
    var recordingState: RecordingState = .idle {
        didSet {
            if recordingState != oldValue {
                DispatchQueue.main.async { [weak self] in self?.controls?.refresh() }
                updateEscapeKey()
                placePill()
            }
        }
    }
    var targets: [CaptureTarget] = []
    var hoveredTarget: String?
    var lastTarget: LastTarget?
    var readyNote: String? {
        didSet { DispatchQueue.main.async { [weak self] in self?.controls?.refresh() } }
    }
    var thumbnails: [UUID: NSImage] = [:]
    var showsSlate = StitchModel.defaults.object(forKey: "showsSlate") as? Bool ?? true {
        didSet { StitchModel.defaults.set(showsSlate, forKey: "showsSlate") }
    }
    var countsDownBeforeRecording = StitchModel.defaults.bool(forKey: "countsDownBeforeRecording") {
        didSet { StitchModel.defaults.set(countsDownBeforeRecording, forKey: "countsDownBeforeRecording") }
    }
    var useGlobalShortcuts = StitchModel.defaults.object(forKey: "useGlobalShortcuts") as? Bool ?? true {
        didSet {
            StitchModel.defaults.set(useGlobalShortcuts, forKey: "useGlobalShortcuts")
            updateGlobalShortcuts()
        }
    }
    enum ShortcutAction {
        case record
        case show
    }

    var recordCombo = StitchModel.storedCombo("recordShortcut") ?? .recordDefault {
        didSet { storeCombo(recordCombo, as: "recordShortcut") }
    }
    var showCombo = StitchModel.storedCombo("showShortcut") ?? .showDefault {
        didSet { storeCombo(showCombo, as: "showShortcut") }
    }
    var editingShortcut: ShortcutAction?
    var shortcutHint: String?
    var shortcutProblem: String?
    var shortcutClashesWithMacOS = false
    @ObservationIgnored private var shortcutMonitor: Any?
    @ObservationIgnored private let hotKeys = GlobalHotKeys(signature: 0x5353_5448)
    @ObservationIgnored private let escapeKey = GlobalHotKeys(signature: 0x5353_4543)
    @ObservationIgnored private var windowVisibility = TargetFrame.Visibility.visible
    @ObservationIgnored private var showsWindowNote = false
    @ObservationIgnored private var askedForAccessibility = false
    var isWindowCovered = false
    var outputThumbnail: NSImage?
    // Set while Quick Look shows the saved video rather than the selected clips.
    @ObservationIgnored private var quickLookOutput: URL?
    var recordMicrophone = StitchModel.defaults.bool(forKey: "recordMicrophone") {
        didSet { StitchModel.defaults.set(recordMicrophone, forKey: "recordMicrophone") }
    }
    var recordingsFolder = StitchModel.defaults.string(forKey: "recordingsFolder")
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? StitchModel.defaultRecordingsFolder {
        didSet { StitchModel.defaults.set(recordingsFolder.path, forKey: "recordingsFolder") }
    }

    private var probing: Set<URL> = []
    @ObservationIgnored private var recorder: Recorder?
    @ObservationIgnored private var controls: RecordingControls?
    @ObservationIgnored private var ourApps: [SCRunningApplication] = []
    @ObservationIgnored private var displays: [SCDisplay] = []
    @ObservationIgnored private var areaSelector: AreaSelector?
    @ObservationIgnored private var areaEditor: AreaEditor?
    @ObservationIgnored private var pill: TargetPill?
    @ObservationIgnored private var slate: Slate?
    @ObservationIgnored private var targetFrame: TargetFrame?
    @ObservationIgnored private var countdownOverlay: CountdownOverlay?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var pendingFilter: SCContentFilter?
    @ObservationIgnored private var pendingArea: CGRect?
    @ObservationIgnored private var pendingTarget: LastTarget?
    private var isManuallyOrdered = false
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var seenFiles: Set<URL> = []
    @ObservationIgnored private var pendingSizes: [URL: Int] = [:]
    @ObservationIgnored private var run: FFmpegRun?
    @ObservationIgnored private var job: EncodeJob?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var recordingActivity: NSObjectProtocol?
    @ObservationIgnored private var quitWhenRecordingEnds: (() -> Void)?

    var isProbing: Bool { !probing.isEmpty }
    var isWatching: Bool { watchFolder != nil }
    var isRecording: Bool { recordingState != .idle }
    var hasBottomBar: Bool {
        !clips.isEmpty || isWatching || warning != nil || notice != nil || state != .idle || isCapturing
    }
    var isCapturing: Bool {
        if case .recording = recordingState { true } else { false }
    }

    nonisolated static let defaultRecordingsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/Screen Stitch", isDirectory: true)

    var isEncoding: Bool { state == .encoding }
    var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } + titleCards.reduce(0) { $0 + $1.duration } }
    var totalBytes: Int64 { clips.reduce(0) { $0 + $1.fileSize } }

    var summary: String {
        guard !clips.isEmpty else { return "" }
        let (width, height, _) = EncodeJob.canvas(for: clips, size: outputSize)
        var count = clips.count == 1 ? "1 clip" : "\(clips.count) clips"
        if !titleCards.isEmpty {
            count += titleCards.count == 1 ? " · 1 title card" : " · \(titleCards.count) title cards"
        }
        return "\(count) · \(formatDuration(totalDuration)) · \(formatBytes(totalBytes)) · Output \(width)×\(height)"
    }

    var progressText: String {
        let percent = "\(Int(progress * 100))%"
        guard progress > 0.02 else { return percent }
        let remaining = Date().timeIntervalSince(startedAt) / progress * (1 - progress)
        return remaining < 60 ? "\(percent) · under a minute left" : "\(percent) · about \(Int((remaining / 60).rounded())) min left"
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie]
        panel.message = "Choose the videos to add"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        guard let tools, !isEncoding else { return }
        let known = Set(clips.map(\.url)).union(probing)
        var fresh: [URL] = []
        for url in urls.map(\.standardizedFileURL) where !known.contains(url) && !fresh.contains(url) {
            fresh.append(url)
        }
        guard !fresh.isEmpty else { return }

        probing.formUnion(fresh)
        clearResult()
        Task {
            let results = await Prober.probeAll(fresh, ffprobe: tools.ffprobe)
            probing.subtract(fresh)
            var added: [Clip] = []
            var skipped: [String] = []
            for (url, clip) in results {
                if let clip {
                    added.append(clip)
                } else {
                    skipped.append(url.lastPathComponent)
                }
            }
            // Once the user has dragged rows around, keep their order and put new clips at the end.
            if isManuallyOrdered {
                items += added.sorted(by: Clip.chronological).map { .clip($0) }
            } else {
                items += added.map { .clip($0) }
                sortClipsKeepingCards()
            }
            warning = skipped.isEmpty ? nil : "Skipped (not a readable video): \(skipped.sorted().joined(separator: ", "))"
            for clip in added {
                Task { await loadThumbnail(for: clip) }
            }
        }
    }

    func toggleRecording() {
        switch recordingState {
        case .idle: startRecording()
        case .recording: stopRecording()
        default: break
        }
    }

    // Record reuses the last window, display or area and goes straight to the floating bar, where Change… reopens
    // the picker. Listing windows needs Screen Recording permission; without it the user can grant it or fall back
    // to the macOS picker, which doesn't.
    func startRecording() {
        beginRecordingFlow(reusingLast: true)
    }

    func pickTarget() {
        beginRecordingFlow(reusingLast: false)
    }

    private func beginRecordingFlow(reusingLast: Bool) {
        guard recordingState == .idle, !isEncoding else { return }
        warning = nil
        do {
            try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        } catch {
            warning = "Couldn't create \(displayPath(recordingsFolder)): \(error.localizedDescription)"
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            recordingState = .needsPermission
            return
        }
        if reusingLast, !clips.isEmpty, let lastTarget {
            recordingState = .starting
            Task { await getReadyAgain(lastTarget) }
        } else {
            showPicker()
        }
    }

    private func showPicker() {
        targets = []
        recordingState = .picking
        Task { await loadTargets() }
    }

    private func fetchContent() async -> SCShareableContent? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            return nil
        }
        ourApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        displays = content.displays
        return content
    }

    private func loadTargets() async {
        guard let content = await fetchContent() else {
            recordingState = .needsPermission
            return
        }
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
        guard recordingState == .picking else { return }
        targets = displays + windows

        let ours = ourApps
        await withTaskGroup(of: (String, CGImage?).self) { group in
            for target in targets {
                group.addTask { (target.id, await target.captureThumbnail(excluding: ours)) }
            }
            for await (id, image) in group {
                if let index = targets.firstIndex(where: { $0.id == id }) {
                    targets[index].thumbnail = image
                }
            }
        }
    }

    private func getReadyAgain(_ last: LastTarget) async {
        guard let content = await fetchContent() else {
            recordingState = .needsPermission
            return
        }
        guard recordingState == .starting else { return }
        switch last {
        case let .window(id, pid, _):
            if let window = content.windows.first(where: { $0.windowID == id }) {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                getReady(filter, area: nil, remembering: last, bringingForward: NSRunningApplication(processIdentifier: pid))
                return
            }
        case let .display(id, _):
            if let display = content.displays.first(where: { $0.displayID == id }) {
                let filter = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])
                getReady(filter, area: nil, remembering: last, bringingForward: nil)
                return
            }
        case let .area(id, rect, _):
            if let display = content.displays.first(where: { $0.displayID == id }) {
                let filter = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])
                getReady(filter, area: rect, remembering: last, bringingForward: nil)
                return
            }
        }
        lastTarget = nil
        warning = "Couldn't find \(last.phrase) anymore. Pick something else to record."
        showPicker()
    }

    func record(_ target: CaptureTarget) {
        guard recordingState == .picking else { return }
        switch target.kind {
        case let .window(window):
            let pid = window.owningApplication?.processID ?? 0
            if target.offScreenReason != nil {
                restore(NSRunningApplication(processIdentifier: pid))
            }
            getReady(
                target.filter(excluding: ourApps),
                area: nil,
                remembering: .window(id: window.windowID, pid: pid, title: target.title),
                bringingForward: NSRunningApplication(processIdentifier: pid)
            )
        case let .display(display):
            getReady(target.filter(excluding: ourApps), area: nil, remembering: .display(id: display.displayID, phrase: target.phrase), bringingForward: nil)
        }
    }

    // The main window steps aside while picking so the area under it can be selected; Esc puts it back.
    func selectArea() {
        guard recordingState == .picking else { return }
        recordingState = .selectingArea
        mainWindow?.orderOut(nil)
        areaSelector = AreaSelector { [weak self] result in
            MainActor.assumeIsolated { self?.areaSelected(result) }
        }
    }

    private func areaSelected(_ result: (screen: NSScreen, rect: CGRect)?) {
        areaSelector = nil
        let id = result?.screen.displayID
        guard let result, let id, let display = displays.first(where: { $0.displayID == id }) else {
            endRecording()
            return
        }
        let rect = result.rect
        let screen = result.screen.frame
        let onScreen = rect.offsetBy(dx: screen.minX, dy: screen.minY)
        let area = CGRect(x: rect.minX, y: screen.height - rect.maxY, width: rect.width, height: rect.height)
        let filter = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])
        getReady(filter, area: area, remembering: .area(display: id, rect: area, onScreen: onScreen), bringingForward: nil)
    }

    static let log = Logger(subsystem: "local.screen-stitch", category: "focus")

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

    // Unhides the app and sends it the reopen event a Dock click sends, which restores a minimized window when the
    // app has no other windows open. Anything else is up to the user, and the floating bar says so.
    private func restore(_ app: NSRunningApplication?) {
        guard let app else { return }
        app.unhide()
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    // Shows the floating bar with Start so the user can set things up first, and hands focus to the window
    // they picked.
    private func getReady(_ filter: SCContentFilter, area: CGRect?, remembering target: LastTarget, bringingForward app: NSRunningApplication?) {
        pendingFilter = filter
        pendingArea = area
        pendingTarget = target
        readyNote = nil
        recordingState = .ready(target.phrase)
        controls = RecordingControls(model: self, on: targetScreen)
        // The app is hidden while the bar is up, and App Nap would throttle the frame's tracking to about once a second.
        if recordingActivity == nil {
            recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording")
        }
        showsWindowNote = false
        isWindowCovered = false
        targetFrame?.remove()
        targetFrame = nil
        areaEditor?.remove()
        areaEditor = nil
        if case .area = target {
            editArea()
        } else {
            targetFrame = frame(for: target)
        }
        placePill()
        if let app {
            NSApp.yieldActivation(to: app)
        }
        NSApp.hide(nil)
        let window: CGWindowID? = if case let .window(id, _, _) = target { id } else { nil }
        if let app {
            Self.bringForward(app, window: window)
        }
        // Activating an app reorders its windows, so the one picked is raised once the app is in front.
        if case let .window(id, pid, _) = target {
            let trusted = AXIsProcessTrusted()
            Self.log.notice("Accessibility \(trusted ? "allowed" : "not allowed", privacy: .public)")
            if trusted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let raised = TargetFrame.raise(window: id, pid: pid)
                    Self.log.notice("Raised the picked window: \(raised, privacy: .public)")
                }
            }
        }
        // Notes wait until the app has had a moment to come forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showsWindowNote = true
            self?.updateWindowNote()
        }
    }

    // Raising one particular window of another app needs Accessibility permission, which Bring to Front asks for.
    private func updateWindowNote() {
        guard showsWindowNote, case .ready = recordingState, case let .window(_, pid, _)? = pendingTarget else { return }
        isWindowCovered = windowVisibility == .covered
        readyNote = switch windowVisibility {
        case .visible: nil
        case .covered where askedForAccessibility && !AXIsProcessTrusted():
            "Turn on Screen Stitch in the System Settings page that opened, then click Bring to Front again."
        case .covered: "Another window is in front of it. You can still click Start."
        case .offScreen: offScreenNote(pid: pid)
        }
    }

    // Without permission, it opens the settings page every time: macOS shows its own prompt only the first time an app
    // ever asks. The request still goes in first, since that's what lists Screen Stitch on the page.
    func bringWindowToFront() {
        guard case let .window(id, pid, _)? = pendingTarget else { return }
        guard AXIsProcessTrusted() else {
            askedForAccessibility = true
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            updateWindowNote()
            return
        }
        TargetFrame.raise(window: id, pid: pid)
    }

    private func frame(for target: LastTarget) -> TargetFrame? {
        switch target {
        case let .window(id, _, _):
            let frame = TargetFrame(.window(id))
            frame.onVisibilityChange = { [weak self] visibility in
                self?.windowVisibility = visibility
                self?.updateWindowNote()
            }
            frame.onMove = { [weak self] in
                self?.placePill()
            }
            frame.onResize = { [weak self] size in
                guard let self else { return }
                switch recordingState {
                case .starting, .recording: recorder?.fit(windowSize: size)
                default: break
                }
            }
            return frame
        case let .display(id, _):
            return NSScreen.screens.first { $0.displayID == id }.map { TargetFrame(.display($0.frame)) }
        case let .area(_, _, onScreen):
            return TargetFrame(.area(onScreen))
        }
    }

    // Start (or Stop) by what's being recorded. A window gets it only when there's room below it; a display never does;
    // an area's Start comes with its editor, and its Stop goes below it or just inside.
    private func placePill() {
        let mode: TargetPill.Mode
        switch recordingState {
        case .ready: mode = .ready(size: nil)
        case let .recording(since): mode = .recording(since: since)
        default:
            pill?.hide()
            return
        }
        var place: (target: CGRect, screen: CGRect, insideIfNeeded: Bool)?
        switch pendingTarget {
        case .window?:
            if let frame = targetFrame?.windowBounds,
               let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
                place = (frame, screen.visibleFrame, false)
            }
        case let .area(id, _, onScreen)?:
            if case .recording = mode, let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
                place = (onScreen, screen.frame, true)
            }
        default:
            break
        }
        guard let place else {
            pill?.hide()
            return
        }
        if pill == nil {
            pill = TargetPill(start: { [weak self] in self?.beginRecording() }, stop: { [weak self] in self?.stopRecording() })
        }
        pill?.show(mode, below: place.target, within: place.screen, insideIfNeeded: place.insideIfNeeded)
    }

    // Until Start, the area can be moved and resized; then it locks into the plain frame clicks pass through.
    private func editArea() {
        guard case let .area(id, _, onScreen)? = pendingTarget,
              let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
        targetFrame?.remove()
        targetFrame = nil
        areaEditor = AreaEditor(rect: onScreen, within: screen.frame, onChange: { [weak self] rect in
            self?.areaMoved(to: rect, on: screen)
        }, onStart: { [weak self] in
            self?.beginRecording()
        })
    }

    private func lockArea() {
        guard let areaEditor, case let .area(_, _, onScreen)? = pendingTarget else { return }
        areaEditor.remove()
        self.areaEditor = nil
        targetFrame = TargetFrame(.area(onScreen))
    }

    private func areaMoved(to onScreen: CGRect, on screen: NSScreen) {
        guard case .ready = recordingState, case let .area(id, _, _)? = pendingTarget else { return }
        let frame = screen.frame
        let area = CGRect(x: onScreen.minX - frame.minX, y: frame.maxY - onScreen.maxY, width: onScreen.width, height: onScreen.height)
        let target = LastTarget.area(display: id, rect: area, onScreen: onScreen)
        pendingArea = area
        pendingTarget = target
        recordingState = .ready(target.phrase)
    }

    private func showSlate() {
        guard showsSlate, let target = pendingTarget else { return }
        let rect: CGRect? = switch target {
        case let .window(id, _, _): TargetFrame.frame(ofWindow: id)
        case let .display(id, _): NSScreen.screens.first { $0.displayID == id }?.frame
        case let .area(_, _, onScreen): onScreen
        }
        guard let rect else { return }
        slate = Slate(over: rect, clipNumber: clips.count + 1)
    }

    // The display what's being recorded is on: the floating bar and the countdown go there.
    private var targetScreen: NSScreen? {
        switch pendingTarget {
        case let .display(id, _)?, let .area(id, _, _)?:
            return NSScreen.screens.first { $0.displayID == id }
        case let .window(id, _, _)?:
            guard let frame = TargetFrame.frame(ofWindow: id) else { return NSScreen.main }
            return NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.main
        case nil:
            return NSScreen.main
        }
    }

    // Optionally counts down 3-2-1 first, so it's obvious when recording starts; the count isn't recorded.
    func beginRecording() {
        guard case .ready = recordingState, pendingFilter != nil else { return }
        if case let .window(id, pid, _)? = pendingTarget, TargetFrame.frame(ofWindow: id) == nil {
            readyNote = offScreenNote(pid: pid)
            return
        }
        readyNote = nil
        isWindowCovered = false
        lastTarget = pendingTarget
        lockArea()
        guard countsDownBeforeRecording else {
            startCapture()
            return
        }
        recordingState = .countdown(3)
        if let screen = targetScreen {
            countdownOverlay = CountdownOverlay(on: screen)
            countdownOverlay?.show(3)
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countDown() }
        }
    }

    private func countDown() {
        guard case let .countdown(remaining) = recordingState else {
            stopCountdown()
            return
        }
        if remaining > 1 {
            recordingState = .countdown(remaining - 1)
            countdownOverlay?.show(remaining - 1)
            return
        }
        stopCountdown()
        startCapture()
    }

    // A window's size is read again at Start: it may have been resized, or restored from the Dock, since it was picked.
    private func startCapture() {
        guard let filter = pendingFilter else { return }
        recordingState = .starting
        showSlate()
        guard case let .window(id, _, _)? = pendingTarget else {
            makeRecorder().record(filter, area: pendingArea)
            return
        }
        Task {
            let window = await fetchContent()?.windows.first { $0.windowID == id }
            guard recordingState == .starting else { return }
            makeRecorder().record(window.map { SCContentFilter(desktopIndependentWindow: $0) } ?? filter, area: nil)
        }
    }

    func cancelCountdown() {
        guard case .countdown = recordingState else { return }
        stopCountdown()
        recordingState = .ready(pendingTarget?.phrase ?? "")
        if case .area? = pendingTarget {
            editArea()
        }
        updateWindowNote()
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownOverlay?.remove()
        countdownOverlay = nil
    }

    func cancelReady() {
        guard case .ready = recordingState else { return }
        endRecording()
    }

    func changeTarget() {
        guard case .ready = recordingState else { return }
        removeRecordingControls()
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        showPicker()
    }

    // Esc cancels from any app while getting ready. It's left alone while recording, where it may be part of what's
    // being recorded.
    private func updateEscapeKey() {
        let gettingReady = switch recordingState {
        case .ready, .countdown, .selectingArea: true
        default: false
        }
        if gettingReady, useGlobalShortcuts {
            _ = escapeKey.register([.init(keyCode: kVK_Escape, modifiers: 0, label: "Esc") { [weak self] in self?.escapePressed() }])
        } else {
            escapeKey.unregister()
        }
    }

    private func escapePressed() {
        switch recordingState {
        case .ready: cancelReady()
        case .countdown: cancelCountdown()
        case .selectingArea: areaSelector?.cancel()
        default: break
        }
    }

    // Also run when the app becomes active, since a shortcut may have been turned off in System Settings meanwhile.
    func updateGlobalShortcuts() {
        updateEscapeKey()
        guard useGlobalShortcuts else {
            hotKeys.unregister()
            shortcutProblem = nil
            shortcutClashesWithMacOS = false
            return
        }
        guard editingShortcut == nil else { return }
        let system = KeyCombo.systemShortcuts()
        let clashing = [recordCombo, showCombo].filter { combo in system.contains { $0.matches(combo) } }
        let failed = hotKeys.register([
            .init(keyCode: recordCombo.keyCode, modifiers: recordCombo.modifiers, label: recordCombo.label) { [weak self] in
                self?.recordShortcut()
            },
            .init(keyCode: showCombo.keyCode, modifiers: showCombo.modifiers, label: showCombo.label) { [weak self] in
                self?.showApp()
            },
        ])
        shortcutClashesWithMacOS = !clashing.isEmpty
        shortcutProblem = if clashing.count == 1 {
            "\(clashing[0].label) won't work because macOS uses it for its own shortcut. Turn it off in Keyboard Shortcuts, or choose other keys."
        } else if clashing.count > 1 {
            "\(clashing.map(\.label).joined(separator: " and ")) won't work because macOS uses them for its own shortcuts. Turn them off in Keyboard Shortcuts, or choose other keys."
        } else if failed.count == 1 {
            "\(failed[0]) won't work because another app already uses it. Choose other keys."
        } else if failed.count > 1 {
            "\(failed.joined(separator: " and ")) won't work because other apps already use them. Choose other keys."
        } else {
            nil
        }
    }

    private static func storedCombo(_ key: String) -> KeyCombo? {
        StitchModel.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
    }

    private func storeCombo(_ combo: KeyCombo, as key: String) {
        StitchModel.defaults.set(try? JSONEncoder().encode(combo), forKey: key)
        updateGlobalShortcuts()
    }

    func combo(for action: ShortcutAction) -> KeyCombo {
        action == .record ? recordCombo : showCombo
    }

    // While a field waits for keys, the global shortcuts are off, so pressing the current ones reaches it. Clicking the
    // field again, or Esc, cancels.
    func editShortcut(_ action: ShortcutAction) {
        let wasEditing = editingShortcut == action
        endEditingShortcut()
        guard !wasEditing else { return }
        editingShortcut = action
        hotKeys.unregister()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.shortcutKeyPressed(event) }
            return nil
        }
    }

    func shortcutKeyPressed(_ event: NSEvent) {
        guard let action = editingShortcut else { return }
        let combo = KeyCombo(event: event)
        if combo.keyCode == kVK_Escape, combo.modifiers == 0 {
            endEditingShortcut()
            return
        }
        guard combo.isAllowed else {
            shortcutHint = "Hold at least two of ⌃ ⌥ ⇧ ⌘ while you press a key, like ⌃⌥R, or use a function key."
            return
        }
        let other: ShortcutAction = action == .record ? .show : .record
        guard !combo.matches(self.combo(for: other)) else {
            shortcutHint = other == .show ? "\(combo.label) already shows Screen Stitch." : "\(combo.label) already starts recording."
            return
        }
        editingShortcut = nil
        switch action {
        case .record: recordCombo = combo
        case .show: showCombo = combo
        }
        endEditingShortcut()
    }

    func endEditingShortcut() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
        }
        shortcutMonitor = nil
        editingShortcut = nil
        shortcutHint = nil
        updateGlobalShortcuts()
    }

    func useDefaultShortcuts() {
        recordCombo = .recordDefault
        showCombo = .showDefault
    }

    func openKeyboardShortcutSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // One shortcut walks through the whole flow: Record, then Start, then Stop.
    private func recordShortcut() {
        switch recordingState {
        case .idle:
            if lastTarget == nil || clips.isEmpty {
                showApp()
            }
            startRecording()
        case .ready:
            beginRecording()
        case .countdown:
            cancelCountdown()
        case .recording:
            stopRecording()
        default:
            showApp()
        }
    }

    func showApp() {
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func primaryRecordingAction() {
        switch recordingState {
        case .ready: beginRecording()
        case .countdown: cancelCountdown()
        case .recording: stopRecording()
        default: break
        }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" }
    }

    func useSystemPicker() {
        guard recordingState == .picking || recordingState == .needsPermission else { return }
        recordingState = .systemPicker
        makeRecorder().pick()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // A detached shell waits for this process to exit, then opens the app again.
    func relaunch() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [
            "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
            Bundle.main.bundlePath,
        ]
        try? shell.run()
        NSApp.terminate(nil)
    }

    private func makeRecorder() -> Recorder {
        let recorder = Recorder(folder: recordingsFolder, microphone: recordMicrophone) { event in
            Task { @MainActor in self.handleRecording(event) }
        }
        self.recorder = recorder
        return recorder
    }

    func stopRecording() {
        recorder?.stop()
    }

    func cancelRecording() {
        switch recordingState {
        case .picking, .needsPermission:
            recordingState = .idle
            targets = []
        case .systemPicker:
            recorder?.cancel()
        default:
            break
        }
    }

    func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = recordingsFolder
        panel.prompt = "Choose"
        panel.message = "Choose where to save new recordings"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        recordingsFolder = folder
    }

    func showRecordingsFolder() {
        try? FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsFolder)
    }

    // The window hides while recording so it stays out of display recordings; the floating bar stops it.
    // Quitting mid-recording would leave an unfinished, unplayable clip, so the clip is finished first. Returns false
    // when there's nothing to finish. The quit goes ahead after 5 seconds regardless.
    func finishRecordingBeforeQuit(then quit: @escaping () -> Void) -> Bool {
        guard let recorder, isCapturing || recordingState == .starting else { return false }
        quitWhenRecordingEnds = quit
        recorder.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.quitIfWaiting()
        }
        return true
    }

    private func quitIfWaiting() {
        let quit = quitWhenRecordingEnds
        quitWhenRecordingEnds = nil
        quit?()
    }

    private func handleRecording(_ event: Recorder.Event) {
        defer {
            if case .started = event {} else { quitIfWaiting() }
        }
        switch event {
        case .started:
            // A start that lands after a cancel belongs to a recording that's already over.
            guard recorder != nil, recordingState == .starting || recordingState == .systemPicker else { return }
            recordingState = .recording(since: Date())
            targetFrame?.recording = true
            NSApp.dockTile.badgeLabel = "REC"
            slate?.clap()
            slate = nil
            if controls == nil {
                controls = RecordingControls(model: self)
                NSApp.hide(nil)
            }
        case let .finished(url):
            endRecording()
            if let url {
                sessionRecordings.insert(url.standardizedFileURL)
                add([url])
            }
        case .cancelled:
            endRecording()
        case let .failed(message):
            endRecording()
            warning = "Recording failed: \(message)"
        }
    }

    private func removeRecordingControls() {
        if let recordingActivity {
            ProcessInfo.processInfo.endActivity(recordingActivity)
            self.recordingActivity = nil
        }
        stopCountdown()
        controls?.remove()
        controls = nil
        targetFrame?.remove()
        targetFrame = nil
        areaEditor?.remove()
        areaEditor = nil
        pill?.hide()
        pill = nil
        slate?.dismiss()
        slate = nil
        readyNote = nil
        isWindowCovered = false
        NSApp.dockTile.badgeLabel = nil
        pendingFilter = nil
        pendingArea = nil
        pendingTarget = nil
    }

    private func endRecording() {
        recorder = nil
        removeRecordingControls()
        recordingState = .idle
        targets = []
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func startWatching(in folder: URL = StitchModel.screenshotFolder()) {
        stopWatching()
        seenFiles = Set(Self.movies(in: folder).map(\.url))
        pendingSizes = [:]
        watchFolder = folder
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWatchFolder() }
        }
    }

    func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
        watchFolder = nil
    }

    func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = watchFolder
        panel.message = "Choose a folder to watch for new screen recordings"
        panel.prompt = "Watch"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        startWatching(in: folder)
    }

    // A file is added once its size stops changing, so recordings still being written are skipped until finished.
    private func checkWatchFolder() {
        guard let folder = watchFolder, !isEncoding, !isRecording else { return }
        var ready: [URL] = []
        for (url, size) in Self.movies(in: folder) where !seenFiles.contains(url) {
            if size > 0, pendingSizes[url] == size {
                seenFiles.insert(url)
                pendingSizes[url] = nil
                ready.append(url)
            } else {
                pendingSizes[url] = size
            }
        }
        if !ready.isEmpty {
            sessionRecordings.formUnion(ready)
            add(ready)
        }
    }

    nonisolated static func screenshotFolder() -> URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                return folder
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private nonisolated static func movies(in folder: URL) -> [(url: URL, size: Int)] {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.contentType?.conforms(to: .movie) == true else {
                return nil
            }
            return (url.standardizedFileURL, values.fileSize ?? 0)
        }
    }

    private func loadThumbnail(for clip: Clip) async {
        thumbnails[clip.id] = await Self.thumbnail(of: clip.url, duration: clip.duration)
    }

    private static func thumbnail(of url: URL, duration: Double) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let time = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        guard let frame = try? await generator.image(at: time) else { return nil }
        return NSImage(cgImage: frame.image, size: .zero)
    }

    // Clicking a thumbnail opens Quick Look on that clip, the same window Space opens.
    func preview(_ clip: Clip) {
        selection = [clip.id]
        quickLookOutput = nil
        showQuickLook()
    }

    func previewOutput() {
        guard case let .done(output, _, _) = state else { return }
        quickLookOutput = output
        showQuickLook()
    }

    // Quick Look shows the selected rows in list order, like the Finder: clips as they are, title cards as a picture of
    // the card. Space opens and closes it.
    var quickLookItems: [URL] {
        if let quickLookOutput {
            return [quickLookOutput]
        }
        return items.filter { selection.contains($0.id) }.compactMap { item in
            switch item {
            case let .clip(clip): clip.url
            case let .card(card): cardPicture(card)
            }
        }
    }

    // Drawn at the video's size, once per version of the card.
    private func cardPicture(_ card: TitleCard) -> URL? {
        let (width, height, _) = clips.isEmpty ? (1280, 720, 1.0) : EncodeJob.canvas(for: clips, size: outputSize)
        let version = "\(card.id.uuidString)\(card.text)\(card.isLight)\(width)x\(height)".hashValue
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-stitch-card-\(UInt(bitPattern: version)).png")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let data = TitleCardImage.png(card, width: width, height: height), (try? data.write(to: url)) != nil else { return nil }
        }
        return url
    }

    // Returns false when there's nothing to show, so the key press can go elsewhere. With nothing selected, it starts
    // at the first row.
    @discardableResult
    func toggleQuickLook() -> Bool {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return true
        }
        guard let first = items.first, !isEncoding else { return false }
        if selection.isEmpty {
            selection = [first.id]
        }
        quickLookOutput = nil
        showQuickLook()
        return true
    }

    private func showQuickLook() {
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // ↑ and ↓ while Quick Look is open move the selection, as they do in the list.
    func moveSelection(by offset: Int) {
        let selected = items.indices.filter { selection.contains(items[$0].id) }
        guard let current = offset < 0 ? selected.first : selected.last else { return }
        let next = min(max(current + offset, 0), items.count - 1)
        selection = [items[next].id]
    }

    func remove(_ clip: Clip) {
        remove(item: clip.id)
        thumbnails[clip.id] = nil
    }

    func remove(item id: UUID) {
        items.removeAll { $0.id == id }
        clearResult()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        isManuallyOrdered = true
        clearResult()
    }

    func sortByDate() {
        sortClipsKeepingCards()
        isManuallyOrdered = false
        clearResult()
    }

    // Puts the clips in recording order, leaving each title card where it is.
    private func sortClipsKeepingCards() {
        var sorted = clips.sorted(by: Clip.chronological).makeIterator()
        items = items.map { item in
            item.clip == nil ? item : sorted.next().map { .clip($0) } ?? item
        }
    }

    var hasBeforeAndAfter: Bool {
        titleCards.contains { $0.role != nil }
    }

    // Before & After is for two clips, one from before a change and one from after.
    var canAddBeforeAndAfter: Bool {
        clips.count == 2 && !hasBeforeAndAfter
    }

    // On: "Before…" above the first clip and "After…" between the two. Off: removes those two, and no other cards.
    func toggleBeforeAndAfter() {
        if hasBeforeAndAfter {
            items.removeAll { $0.card?.role != nil }
        } else {
            guard canAddBeforeAndAfter else { return }
            items.insert(.card(TitleCard(text: "Before…", role: .before)), at: 0)
            let after = items.firstIndex { $0.clip != nil }.map { $0 + 1 } ?? items.count
            items.insert(.card(TitleCard(text: "After…", role: .after)), at: after)
        }
        clearResult()
    }

    // After the selected row, or at the end.
    func addTitleCard() {
        let card = TitleCard(text: "Title")
        let index = items.lastIndex { selection.contains($0.id) }.map { $0 + 1 } ?? items.count
        items.insert(.card(card), at: index)
        clearResult()
    }

    func updateCard(_ id: UUID, _ change: (inout TitleCard) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), var card = items[index].card else { return }
        change(&card)
        items[index] = .card(card)
        clearResult()
    }

    func clear() {
        items = []
        thumbnails = [:]
        isManuallyOrdered = false
        warning = nil
        sessionRecordings = []
        sessionOutputs = []
    }

    private func offScreenNote(pid: pid_t) -> String {
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "app"
        return "The window isn't on screen. Click the \(app) icon in the Dock, or the window itself there if it's minimized, then click Start."
    }

    enum ClearAction {
        case keepFiles
        case moveClips
        case moveEverything
    }

    // The combined videos that still exist, other than any that were added back in as clips.
    var existingOutputs: [URL] {
        let clipURLs = Set(clips.map(\.url))
        return sessionOutputs.filter { !clipURLs.contains($0) && FileManager.default.fileExists(atPath: $0.path) }
    }

    // Each choice says what it moves, so "everything" can't be taken to mean the whole folder.
    var clearPrompt: (title: String, message: String, offersEverything: Bool) {
        let count = clips.count
        let title = isCombined ? "Clear this session?"
            : count == 1 ? "Clear this session without compressing its clip?"
            : "Clear this session without combining its \(count) clips?"
        var message = "Keep Files leaves every file where it is. "
            + (count == 1 ? "Move Clips to Trash moves the clip in the list" : "Move Clips to Trash moves the \(count) clips in the list")
        let added = clips.filter { !sessionRecordings.contains($0.url) }.count
        if added == count {
            message += count == 1 ? ", which you added from elsewhere" : ", all added from elsewhere"
        } else if added > 0 {
            message += ", including \(added) you added from elsewhere"
        }
        message += "."
        let outputs = existingOutputs
        let theClips = count == 1 ? "the clip" : "the clips"
        if outputs.count == 1 {
            message += " Move Everything to Trash moves \(theClips) and the saved video, “\(outputs[0].lastPathComponent)”."
        } else if outputs.count > 1 {
            message += " Move Everything to Trash moves \(theClips) and the \(outputs.count) videos saved in this session."
        }
        message += (outputs.isEmpty ? "" : " Nothing else is touched.") + " You can put back anything moved to the Trash."
        return (title, message, !outputs.isEmpty)
    }

    // Ends the session, asking what to do with its files.
    func clearSession() {
        guard !clips.isEmpty else {
            clearSession(.keepFiles)
            return
        }
        let prompt = clearPrompt
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        // Return keeps the files. NSAlert would make Keep Files the default anyway; this doesn't leave it to chance.
        alert.addButton(withTitle: "Keep Files").keyEquivalent = "\r"
        alert.addButton(withTitle: "Move Clips to Trash").hasDestructiveAction = true
        var actions: [ClearAction] = [.keepFiles, .moveClips]
        if prompt.offersEverything {
            alert.addButton(withTitle: "Move Everything to Trash").hasDestructiveAction = true
            actions.append(.moveEverything)
        }
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard actions.indices.contains(choice) else { return }
        clearSession(actions[choice])
    }

    // Only files the session knows about are moved: its clips and the videos combined from them.
    func clearSession(_ action: ClearAction) {
        let files = switch action {
        case .keepFiles: [URL]()
        case .moveClips: clips.map(\.url)
        case .moveEverything: clips.map(\.url) + existingOutputs
        }
        var failed: [String] = []
        for file in files {
            do {
                try moveToTrash(file)
            } catch {
                failed.append(file.lastPathComponent)
            }
        }
        clear()
        state = .idle
        let moved = files.count - failed.count
        notice = moved == 0 ? nil : moved == 1 ? "Moved 1 file to the Trash." : "Moved \(moved) files to the Trash."
        if !failed.isEmpty {
            warning = "Couldn't move to the Trash: \(failed.joined(separator: ", "))"
        }
    }

    private var isCombined: Bool {
        if case .done = state { true } else { false }
    }

    var isDateOrdered: Bool {
        !isManuallyOrdered
    }

    // Title cards have to be drawn into the video, so a session with any can't be joined as is.
    var canCombineWithoutCompressing: Bool {
        titleCards.isEmpty && EncodeJob.canJoin(clips)
    }

    func chooseOutputAndEncode(compressing: Bool = true) {
        guard let first = clips.first else { return }
        let single = clips.count == 1
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = first.url.deletingLastPathComponent()
        panel.nameFieldStringValue = first.url.deletingPathExtension().lastPathComponent + (single ? " compressed.mp4" : " combined.mp4")
        panel.message = single ? "Choose where to save the compressed video" : "Choose where to save the combined video"
        guard panel.runModal() == .OK, let output = panel.url?.standardizedFileURL else { return }
        guard !clips.contains(where: { $0.url == output }) else {
            state = .failed(single
                ? "That file is the clip being compressed. Choose a different name or folder."
                : "That file is one of the clips being combined. Choose a different name or folder.")
            return
        }
        encode(to: output, compressing: compressing)
    }

    func encode(to output: URL, compressing: Bool = true) {
        guard let tools, !clips.isEmpty, !isEncoding else { return }
        let temporary = FileManager.default.temporaryDirectory
        var job: EncodeJob
        do {
            if compressing {
                let (width, height, _) = EncodeJob.canvas(for: clips, size: outputSize)
                var images: [URL] = []
                let segments: [EncodeJob.Segment] = try items.map { item in
                    switch item {
                    case let .clip(clip):
                        return .clip(clip)
                    case let .card(card):
                        let image = temporary.appendingPathComponent("screen-stitch-card-\(UUID().uuidString).png")
                        guard let data = TitleCardImage.png(card, width: width, height: height) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        try data.write(to: image)
                        images.append(image)
                        return .card(card, image: image)
                    }
                }
                job = EncodeJob(segments: segments, size: outputSize, quality: quality, output: output)
                job.temporaryFiles = images
            } else {
                guard canCombineWithoutCompressing else { return }
                job = EncodeJob(clips: clips, size: outputSize, quality: quality, output: output)
                let list = temporary.appendingPathComponent("screen-stitch-\(UUID().uuidString).txt")
                try job.concatList.write(to: list, atomically: true, encoding: .utf8)
                job.mode = .join(list: list)
                job.temporaryFiles = [list]
            }
        } catch {
            state = .failed("Couldn't \(clips.count == 1 ? "compress the clip" : "combine the clips"): \(error.localizedDescription)")
            return
        }
        let run = FFmpegRun()
        startedAt = Date()
        do {
            try run.start(
                ffmpeg: tools.ffmpeg,
                arguments: job.arguments,
                duration: job.duration,
                onProgress: { value in Task { @MainActor in self.progress = value } },
                onExit: { status, errors in Task { @MainActor in self.finish(status: status, errors: errors) } }
            )
        } catch {
            state = .failed("Couldn't start FFmpeg: \(error.localizedDescription)")
            return
        }
        self.run = run
        self.job = job
        // Standardizing only strips /private from paths that exist, so do it on the folder.
        seenFiles.insert(output.deletingLastPathComponent().standardizedFileURL.appendingPathComponent(output.lastPathComponent))
        cancelled = false
        progress = 0
        state = .encoding
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Encoding video"
        )
    }

    func cancel() {
        guard isEncoding, let run else { return }
        cancelled = true
        run.forceStop()
    }

    func abortForQuit() {
        guard isEncoding, let run, let job else { return }
        run.forceStopAndWait()
        removePartialOutput(of: job)
    }

    // A failed or cancelled run leaves a partial file, unless FFmpeg stopped before writing; then any file of that name
    // is one the user chose to replace, and it's kept.
    private func removePartialOutput(of job: EncodeJob) {
        job.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        let modified = try? job.output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let modified, modified >= startedAt.addingTimeInterval(-1) {
            try? FileManager.default.removeItem(at: job.output)
        }
    }

    private func finish(status: Int32, errors: String) {
        guard let job else { return }
        self.run = nil
        self.job = nil
        job.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }

        if cancelled {
            removePartialOutput(of: job)
            state = .idle
        } else if status == 0 {
            let bytes = (try? job.output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            progress = 1
            let output = job.output.standardizedFileURL
            if !sessionOutputs.contains(output) {
                sessionOutputs.append(output)
            }
            state = .done(output: job.output, outputBytes: Int64(bytes), inputBytes: clips.reduce(0) { $0 + $1.fileSize })
            NSApp?.requestUserAttention(.informationalRequest)
            Task {
                let image = await Self.thumbnail(of: job.output, duration: job.duration)
                if case .done(job.output, _, _) = state {
                    outputThumbnail = image
                }
            }
        } else {
            removePartialOutput(of: job)
            let action = job.clips.count == 1 ? "compress the clip" : "combine the clips"
            state = .failed(errors.isEmpty
                ? "Couldn't \(action) (FFmpeg exited with status \(status))."
                : "Couldn't \(action). FFmpeg reported:\n\(errors)")
        }
    }

    private func clearResult() {
        if !isEncoding {
            state = .idle
        }
    }
}
