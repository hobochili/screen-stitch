import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

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

// ScreenCaptureKit, as the recording flow uses it: what can be recorded, getting it ready, and recording it.
@MainActor
protocol CaptureSource: AnyObject {
    // Screen Recording permission. Asking shows macOS's prompt only the first time.
    var canCapture: Bool { get }
    func askForPermission()
    // The windows and displays to choose from, or nil without permission. Thumbnails arrive one by one.
    func targets() async -> [CaptureTarget]?
    func loadThumbnails(for targets: [CaptureTarget], each: @escaping (String, CGImage?) -> Void) async
    // Gets something ready to record. `find` looks up a target picked earlier: false when it's gone, nil without
    // permission.
    func prepare(_ target: CaptureTarget)
    func prepare(display id: CGDirectDisplayID) -> Bool
    func find(_ target: LastTarget) async -> Bool?
    var isPrepared: Bool { get }
    // A window is looked up again just before recording, since it may have been resized or restored meanwhile.
    func refresh(window id: CGWindowID) async
    // Records what's ready, or lets the user choose in the macOS picker. Events arrive on the main actor.
    func record(area: CGRect?, microphone: Bool, into folder: URL, events: @escaping @MainActor (Recorder.Event) -> Void)
    func pick(microphone: Bool, into folder: URL, events: @escaping @MainActor (Recorder.Event) -> Void)
    func stop()
    func cancel()
    func fit(windowSize: CGSize)
    // Drops what was ready and the finished recorder.
    func forget()
}

// What the recording flow puts on screen, and the app's own windows.
@MainActor
protocol RecordingOverlays: AnyObject {
    // Hides the app, handing focus to the app being recorded and raising the picked window.
    func hideApp(handingFocusTo pid: pid_t?, window: CGWindowID?)
    func showApp()
    func hideMainWindow()
    // Sends a hidden or minimized app the reopen event a Dock click sends.
    func restore(pid: pid_t)
    var isAccessibilityAllowed: Bool { get }
    func askForAccessibility()
    func raise(window: CGWindowID, pid: pid_t)
    func setRecordingBadge(_ on: Bool)
    // Where a window is now, or nil when it's off screen.
    func frame(ofWindow id: CGWindowID) -> CGRect?

    // The floating bar, which reads the flow itself.
    func showBar(near target: LastTarget?)
    func refreshBar()
    func removeBar()

    // The outline around what's being recorded. A window's reports its moves, resizes and visibility.
    func showFrame(around target: LastTarget, onMove: @escaping () -> Void, onResize: @escaping (CGSize) -> Void,
                   onVisibilityChange: @escaping (TargetFrame.Visibility) -> Void)
    func markFrameRecording()
    func removeFrame()

    // Dragging out an area: the result is its display, that display's frame, and the rect within it.
    func selectArea(done: @escaping ((display: CGDirectDisplayID, screen: CGRect, rect: CGRect)?) -> Void)
    func cancelAreaSelection()
    // Moving and resizing it before Start. Changes come with the frame of the display it's on.
    func editArea(_ onScreen: CGRect, on display: CGDirectDisplayID, onChange: @escaping (CGRect, CGRect) -> Void,
                  onStart: @escaping () -> Void)
    func removeAreaEditor()

    // Start or Stop next to the target, if there's room for it.
    func showPill(_ mode: TargetPill.Mode, by target: LastTarget, start: @escaping () -> Void, stop: @escaping () -> Void)
    func hidePill()

    // 3-2-1, calling `tick` each second until it's removed.
    func showCountdown(_ count: Int, near target: LastTarget?, tick: @escaping () -> Void)
    func updateCountdown(_ count: Int)
    func removeCountdown()

    // The clapperboard that marks the start of a clip.
    func showSlate(over target: LastTarget, clipNumber: Int)
    func clapSlate()
    func dismissSlate()
}

// Picking what to record, getting ready, the countdown, recording and stopping. The model keeps the clips and settings;
// ScreenCaptureKit and everything on screen are behind `CaptureSource` and `RecordingOverlays`, which tests replace.
@MainActor
@Observable
final class RecordingFlow {
    var state: RecordingState = .idle {
        didSet {
            if state != oldValue {
                overlays.refreshBar()
                updateEscapeKey()
                placePill()
            }
        }
    }
    var targets: [CaptureTarget] = []
    var hoveredTarget: String?
    var lastTarget: LastTarget?
    var readyNote: String? {
        didSet { overlays.refreshBar() }
    }
    var isWindowCovered = false

    var isRecording: Bool { state != .idle }
    var isCapturing: Bool {
        if case .recording = state { true } else { false }
    }

    @ObservationIgnored private weak var model: StitchModel?
    @ObservationIgnored private let source: CaptureSource
    @ObservationIgnored private let overlays: RecordingOverlays
    @ObservationIgnored private let escapeKey = GlobalHotKeys(signature: 0x5353_4543)
    @ObservationIgnored private var pendingTarget: LastTarget?
    @ObservationIgnored private var showsBar = false
    @ObservationIgnored private var isEditingArea = false
    @ObservationIgnored private var hasRecorder = false
    @ObservationIgnored private var windowVisibility = TargetFrame.Visibility.visible
    @ObservationIgnored private var showsWindowNote = false
    @ObservationIgnored private var askedForAccessibility = false
    @ObservationIgnored private var recordingActivity: NSObjectProtocol?
    @ObservationIgnored private var quitWhenRecordingEnds: (() -> Void)?

    init(model: StitchModel, source: CaptureSource, overlays: RecordingOverlays) {
        self.model = model
        self.source = source
        self.overlays = overlays
    }

    func toggleRecording() {
        switch state {
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
        guard state == .idle, let model, !model.isEncoding else { return }
        model.warning = nil
        do {
            try FileManager.default.createDirectory(at: model.recordingsFolder, withIntermediateDirectories: true)
        } catch {
            model.warning = "Couldn't create \(displayPath(model.recordingsFolder)): \(error.localizedDescription)"
            return
        }
        guard source.canCapture else {
            source.askForPermission()
            state = .needsPermission
            return
        }
        if reusingLast, !model.clips.isEmpty, let lastTarget {
            state = .starting
            Task { await getReadyAgain(lastTarget) }
        } else {
            showPicker()
        }
    }

    private func showPicker() {
        targets = []
        state = .picking
        Task { await loadTargets() }
    }

    private func loadTargets() async {
        guard let found = await source.targets() else {
            state = .needsPermission
            return
        }
        guard state == .picking else { return }
        targets = found
        await source.loadThumbnails(for: found) { [weak self] id, image in
            guard let self, let index = targets.firstIndex(where: { $0.id == id }) else { return }
            targets[index].thumbnail = image
        }
    }

    private func getReadyAgain(_ last: LastTarget) async {
        guard let found = await source.find(last) else {
            state = .needsPermission
            return
        }
        guard state == .starting else { return }
        if found {
            let pid: pid_t? = if case let .window(_, pid, _) = last { pid } else { nil }
            getReady(remembering: last, bringingForward: pid)
            return
        }
        lastTarget = nil
        model?.warning = "Couldn't find \(last.phrase) anymore. Pick something else to record."
        showPicker()
    }

    func record(_ target: CaptureTarget) {
        guard state == .picking else { return }
        switch target.kind {
        case let .window(window):
            let pid = window.owningApplication?.processID ?? 0
            if target.offScreenReason != nil {
                overlays.restore(pid: pid)
            }
            source.prepare(target)
            getReady(remembering: .window(id: window.windowID, pid: pid, title: target.title), bringingForward: pid)
        case let .display(display):
            source.prepare(target)
            getReady(remembering: .display(id: display.displayID, phrase: target.phrase), bringingForward: nil)
        }
    }

    // The main window steps aside while picking so the area under it can be selected; Esc puts it back.
    func selectArea() {
        guard state == .picking else { return }
        state = .selectingArea
        overlays.hideMainWindow()
        overlays.selectArea { [weak self] result in
            self?.areaSelected(result)
        }
    }

    private func areaSelected(_ result: (display: CGDirectDisplayID, screen: CGRect, rect: CGRect)?) {
        guard let result, source.prepare(display: result.display) else {
            endRecording()
            return
        }
        let rect = result.rect
        let screen = result.screen
        let onScreen = rect.offsetBy(dx: screen.minX, dy: screen.minY)
        let area = CGRect(x: rect.minX, y: screen.height - rect.maxY, width: rect.width, height: rect.height)
        getReady(remembering: .area(display: result.display, rect: area, onScreen: onScreen), bringingForward: nil)
    }

    // Shows the floating bar with Start so the user can set things up first, and hands focus to the window
    // they picked.
    private func getReady(remembering target: LastTarget, bringingForward pid: pid_t?) {
        pendingTarget = target
        readyNote = nil
        state = .ready(target.phrase)
        overlays.showBar(near: target)
        showsBar = true
        // The app is hidden while the bar is up, and App Nap would throttle the frame's tracking to about once a second.
        if recordingActivity == nil {
            recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording")
        }
        showsWindowNote = false
        isWindowCovered = false
        overlays.removeFrame()
        overlays.removeAreaEditor()
        isEditingArea = false
        if case .area = target {
            editArea()
        } else {
            showFrame(around: target)
        }
        placePill()
        let window: CGWindowID? = if case let .window(id, _, _) = target { id } else { nil }
        overlays.hideApp(handingFocusTo: pid, window: window)
        // Notes wait until the app has had a moment to come forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showsWindowNote = true
            self?.updateWindowNote()
        }
    }

    // Raising one particular window of another app needs Accessibility permission, which Bring to Front asks for.
    private func updateWindowNote() {
        guard showsWindowNote, case .ready = state, case let .window(_, pid, _)? = pendingTarget else { return }
        isWindowCovered = windowVisibility == .covered
        readyNote = switch windowVisibility {
        case .visible: nil
        case .covered where askedForAccessibility && !overlays.isAccessibilityAllowed:
            "Turn on Screen Stitch in the System Settings page that opened, then click Bring to Front again."
        case .covered: "Another window is in front of it. You can still click Start."
        case .offScreen: offScreenNote(pid: pid)
        }
    }

    // Without permission, it opens the settings page every time: macOS shows its own prompt only the first time an app
    // ever asks. The request still goes in first, since that's what lists Screen Stitch on the page.
    func bringWindowToFront() {
        guard case let .window(id, pid, _)? = pendingTarget else { return }
        guard overlays.isAccessibilityAllowed else {
            askedForAccessibility = true
            overlays.askForAccessibility()
            updateWindowNote()
            return
        }
        overlays.raise(window: id, pid: pid)
    }

    private func offScreenNote(pid: pid_t) -> String {
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "app"
        return "The window isn't on screen. Click the \(app) icon in the Dock, or the window itself there if it's minimized, then click Start."
    }

    private func showFrame(around target: LastTarget) {
        overlays.showFrame(around: target, onMove: { [weak self] in
            self?.placePill()
        }, onResize: { [weak self] size in
            guard let self else { return }
            switch state {
            case .starting, .recording: source.fit(windowSize: size)
            default: break
            }
        }, onVisibilityChange: { [weak self] visibility in
            self?.windowVisibility = visibility
            self?.updateWindowNote()
        })
    }

    // Start (or Stop) by what's being recorded. A window gets it when there's room; a display never does; an area's
    // Start comes with its editor, and its Stop goes below it or just inside.
    private func placePill() {
        let mode: TargetPill.Mode
        switch state {
        case .ready: mode = .ready(size: nil)
        case let .recording(since): mode = .recording(since: since)
        default:
            overlays.hidePill()
            return
        }
        switch pendingTarget {
        case let target? where target.isWindow || (target.isArea && mode != .ready(size: nil)):
            overlays.showPill(mode, by: target, start: { [weak self] in
                self?.beginRecording()
            }, stop: { [weak self] in
                self?.stopRecording()
            })
        default:
            overlays.hidePill()
        }
    }

    // Until Start, the area can be moved and resized; then it locks into the plain frame clicks pass through.
    private func editArea() {
        guard case let .area(id, _, onScreen)? = pendingTarget else { return }
        overlays.removeFrame()
        overlays.editArea(onScreen, on: id, onChange: { [weak self] rect, screen in
            self?.areaMoved(to: rect, on: screen)
        }, onStart: { [weak self] in
            self?.beginRecording()
        })
        isEditingArea = true
    }

    private func lockArea() {
        guard isEditingArea, let target = pendingTarget, target.isArea else { return }
        overlays.removeAreaEditor()
        isEditingArea = false
        showFrame(around: target)
    }

    private func areaMoved(to onScreen: CGRect, on screen: CGRect) {
        guard case .ready = state, case let .area(id, _, _)? = pendingTarget else { return }
        let area = CGRect(x: onScreen.minX - screen.minX, y: screen.maxY - onScreen.maxY, width: onScreen.width, height: onScreen.height)
        let target = LastTarget.area(display: id, rect: area, onScreen: onScreen)
        pendingTarget = target
        state = .ready(target.phrase)
    }

    private func showSlate() {
        guard let model, model.showsSlate, let target = pendingTarget else { return }
        overlays.showSlate(over: target, clipNumber: model.clips.count + 1)
    }

    // Optionally counts down 3-2-1 first, so it's obvious when recording starts; the count isn't recorded.
    func beginRecording() {
        guard case .ready = state, source.isPrepared else { return }
        if case let .window(id, pid, _)? = pendingTarget, overlays.frame(ofWindow: id) == nil {
            readyNote = offScreenNote(pid: pid)
            return
        }
        readyNote = nil
        isWindowCovered = false
        lastTarget = pendingTarget
        lockArea()
        guard model?.countsDownBeforeRecording == true else {
            startCapture()
            return
        }
        state = .countdown(3)
        overlays.showCountdown(3, near: pendingTarget) { [weak self] in
            self?.countDown()
        }
    }

    private func countDown() {
        guard case let .countdown(remaining) = state else {
            overlays.removeCountdown()
            return
        }
        if remaining > 1 {
            state = .countdown(remaining - 1)
            overlays.updateCountdown(remaining - 1)
            return
        }
        overlays.removeCountdown()
        startCapture()
    }

    // A window's size is read again at Start: it may have been resized, or restored from the Dock, since it was picked.
    private func startCapture() {
        guard source.isPrepared else { return }
        state = .starting
        showSlate()
        guard case let .window(id, _, _)? = pendingTarget else {
            record()
            return
        }
        Task {
            await source.refresh(window: id)
            guard state == .starting else { return }
            record()
        }
    }

    private func record() {
        guard let model else { return }
        hasRecorder = true
        let area: CGRect? = if case let .area(_, rect, _)? = pendingTarget { rect } else { nil }
        source.record(area: area, microphone: model.recordMicrophone, into: model.recordingsFolder) { [weak self] event in
            self?.handle(event)
        }
    }

    func cancelCountdown() {
        guard case .countdown = state else { return }
        overlays.removeCountdown()
        state = .ready(pendingTarget?.phrase ?? "")
        if pendingTarget?.isArea == true {
            editArea()
        }
        updateWindowNote()
    }

    func cancelReady() {
        guard case .ready = state else { return }
        endRecording()
    }

    func changeTarget() {
        guard case .ready = state else { return }
        removeRecordingControls()
        overlays.showApp()
        showPicker()
    }

    // Esc cancels from any app while getting ready. It's left alone while recording, where it may be part of what's
    // being recorded.
    func updateEscapeKey() {
        let gettingReady = switch state {
        case .ready, .countdown, .selectingArea: true
        default: false
        }
        if gettingReady, model?.useGlobalShortcuts == true {
            _ = escapeKey.register([.init(keyCode: kVK_Escape, modifiers: 0, label: "Esc") { [weak self] in self?.escapePressed() }])
        } else {
            escapeKey.unregister()
        }
    }

    func escapePressed() {
        switch state {
        case .ready: cancelReady()
        case .countdown: cancelCountdown()
        case .selectingArea: overlays.cancelAreaSelection()
        default: break
        }
    }

    // One shortcut walks through the whole flow: Record, then Start, then Stop.
    func recordShortcut() {
        switch state {
        case .idle:
            if lastTarget == nil || model?.clips.isEmpty != false {
                overlays.showApp()
            }
            startRecording()
        case .ready:
            beginRecording()
        case .countdown:
            cancelCountdown()
        case .recording:
            stopRecording()
        default:
            overlays.showApp()
        }
    }

    func primaryRecordingAction() {
        switch state {
        case .ready: beginRecording()
        case .countdown: cancelCountdown()
        case .recording: stopRecording()
        default: break
        }
    }

    func useSystemPicker() {
        guard state == .picking || state == .needsPermission, let model else { return }
        state = .systemPicker
        hasRecorder = true
        source.pick(microphone: model.recordMicrophone, into: model.recordingsFolder) { [weak self] event in
            self?.handle(event)
        }
    }

    func stopRecording() {
        source.stop()
    }

    func cancelRecording() {
        switch state {
        case .picking, .needsPermission:
            state = .idle
            targets = []
        case .systemPicker:
            source.cancel()
        default:
            break
        }
    }

    // The window hides while recording so it stays out of display recordings; the floating bar stops it.
    // Quitting mid-recording would leave an unfinished, unplayable clip, so the clip is finished first. Returns false
    // when there's nothing to finish. The quit goes ahead after 5 seconds regardless.
    func finishRecordingBeforeQuit(then quit: @escaping () -> Void) -> Bool {
        guard hasRecorder, isCapturing || state == .starting else { return false }
        quitWhenRecordingEnds = quit
        source.stop()
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

    private func handle(_ event: Recorder.Event) {
        defer {
            if case .started = event {} else { quitIfWaiting() }
        }
        switch event {
        case .started:
            // A start that lands after a cancel belongs to a recording that's already over.
            guard hasRecorder, state == .starting || state == .systemPicker else { return }
            state = .recording(since: Date())
            overlays.markFrameRecording()
            overlays.setRecordingBadge(true)
            overlays.clapSlate()
            if !showsBar {
                overlays.showBar(near: nil)
                showsBar = true
                overlays.hideApp(handingFocusTo: nil, window: nil)
            }
        case let .finished(url):
            endRecording()
            if let url {
                model?.sessionRecordings.insert(url.standardizedFileURL)
                model?.add([url])
            }
        case .cancelled:
            endRecording()
        case let .failed(message):
            endRecording()
            model?.warning = "Recording failed: \(message)"
        }
    }

    private func removeRecordingControls() {
        if let recordingActivity {
            ProcessInfo.processInfo.endActivity(recordingActivity)
            self.recordingActivity = nil
        }
        overlays.removeCountdown()
        overlays.removeBar()
        showsBar = false
        overlays.removeFrame()
        overlays.removeAreaEditor()
        isEditingArea = false
        overlays.hidePill()
        overlays.dismissSlate()
        readyNote = nil
        isWindowCovered = false
        overlays.setRecordingBadge(false)
        source.forget()
        pendingTarget = nil
    }

    private func endRecording() {
        hasRecorder = false
        removeRecordingControls()
        state = .idle
        targets = []
        overlays.showApp()
    }
}

extension LastTarget {
    var isWindow: Bool {
        if case .window = self { true } else { false }
    }

    var isArea: Bool {
        if case .area = self { true } else { false }
    }
}
