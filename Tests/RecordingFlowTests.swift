import AppKit
import Testing

// ScreenCaptureKit stand-in: everything is found and ready, and the test sends the recorder's events.
@MainActor
final class FakeCaptureSource: CaptureSource {
    var canCapture = true
    var askedForPermission = false
    // What looking up a target picked earlier finds: true, false when it's gone, nil without permission.
    var found: Bool? = true
    var isPrepared = false
    var calls: [String] = []
    private var events: (@MainActor (Recorder.Event) -> Void)?

    func askForPermission() { askedForPermission = true }
    func targets() async -> [CaptureTarget]? { canCapture ? [] : nil }
    func loadThumbnails(for targets: [CaptureTarget], each: @escaping (String, CGImage?) -> Void) async {}
    func prepare(_ target: CaptureTarget) { isPrepared = true }

    func prepare(display id: CGDirectDisplayID) -> Bool {
        isPrepared = true
        return true
    }

    func find(_ target: LastTarget) async -> Bool? {
        if found == true { isPrepared = true }
        return found
    }

    func refresh(window id: CGWindowID) async {}

    func record(area: CGRect?, microphone: Bool, into folder: URL, events: @escaping @MainActor (Recorder.Event) -> Void) {
        calls.append(area.map { "record \(Int($0.width))×\(Int($0.height))" } ?? "record")
        self.events = events
    }

    func pick(microphone: Bool, into folder: URL, events: @escaping @MainActor (Recorder.Event) -> Void) {
        calls.append("pick")
        self.events = events
    }

    func stop() { calls.append("stop") }
    func cancel() { calls.append("cancel") }
    func fit(windowSize: CGSize) { calls.append("fit \(Int(windowSize.width))×\(Int(windowSize.height))") }
    func forget() { isPrepared = false }

    // As the recorder would.
    func send(_ event: Recorder.Event) {
        events?(event)
    }
}

// Screen stand-in: keeps track of what would be showing.
@MainActor
final class FakeOverlays: RecordingOverlays {
    var isAppHidden = false
    var focusedPID: pid_t?
    var badge = false
    var bar = false
    var frame: String?
    var frameRecording = false
    var editingArea = false
    var pill: String?
    var countdown: Int?
    var slate = false
    var calls: [String] = []
    var isAccessibilityAllowed = false
    var windowFrames: [CGWindowID: CGRect] = [:]
    // What the flow handed over, for the test to call.
    var tick: (() -> Void)?
    var resize: ((CGSize) -> Void)?
    var moveArea: ((CGRect, CGRect) -> Void)?
    var areaSelected: (((display: CGDirectDisplayID, screen: CGRect, rect: CGRect)?) -> Void)?

    func hideApp(handingFocusTo pid: pid_t?, window: CGWindowID?) {
        isAppHidden = true
        focusedPID = pid
    }

    func showApp() { isAppHidden = false }
    func hideMainWindow() { calls.append("hide main window") }
    func restore(pid: pid_t) { calls.append("restore") }
    func askForAccessibility() { calls.append("ask for Accessibility") }
    func raise(window: CGWindowID, pid: pid_t) { calls.append("raise") }
    func setRecordingBadge(_ on: Bool) { badge = on }
    func frame(ofWindow id: CGWindowID) -> CGRect? { windowFrames[id] }
    func showBar(near target: LastTarget?) { bar = true }
    func refreshBar() {}
    func removeBar() { bar = false }

    func showFrame(around target: LastTarget, onMove: @escaping () -> Void, onResize: @escaping (CGSize) -> Void,
                   onVisibilityChange: @escaping (TargetFrame.Visibility) -> Void) {
        frame = switch target {
        case .window: "window"
        case .display: "display"
        case .area: "area"
        }
        frameRecording = false
        resize = onResize
    }

    func markFrameRecording() { frameRecording = true }

    func removeFrame() {
        frame = nil
        frameRecording = false
    }

    func selectArea(done: @escaping ((display: CGDirectDisplayID, screen: CGRect, rect: CGRect)?) -> Void) {
        areaSelected = done
    }

    // Like the real selector, Esc ends it with nothing selected.
    func cancelAreaSelection() {
        calls.append("cancel area selection")
        areaSelected?(nil)
    }

    func editArea(_ onScreen: CGRect, on display: CGDirectDisplayID, onChange: @escaping (CGRect, CGRect) -> Void,
                  onStart: @escaping () -> Void) {
        editingArea = true
        moveArea = onChange
    }

    func removeAreaEditor() { editingArea = false }

    func showPill(_ mode: TargetPill.Mode, by target: LastTarget, start: @escaping () -> Void, stop: @escaping () -> Void) {
        pill = if case .ready = mode { "Start" } else { "Stop" }
    }

    func hidePill() { pill = nil }

    func showCountdown(_ count: Int, near target: LastTarget?, tick: @escaping () -> Void) {
        countdown = count
        self.tick = tick
    }

    func updateCountdown(_ count: Int) { countdown = count }

    func removeCountdown() {
        countdown = nil
        tick = nil
    }

    func showSlate(over target: LastTarget, clipNumber: Int) { slate = true }

    func clapSlate() {
        slate = false
        calls.append("clap")
    }

    func dismissSlate() { slate = false }
}

private let notes = LastTarget.window(id: 42, pid: 4242, title: "Notes")
private let display = LastTarget.display(id: 1, phrase: "the entire screen")
private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let area = LastTarget.area(display: 1, rect: CGRect(x: 100, y: 500, width: 400, height: 200),
                                   onScreen: CGRect(x: 100, y: 100, width: 400, height: 200))

@MainActor
@Suite(.serialized) struct RecordingFlowTests {
    private let source = FakeCaptureSource()
    private let overlays = FakeOverlays()
    private let folder: TemporaryFolder
    private let model: StitchModel
    private var flow: RecordingFlow { model.recording }

    init() throws {
        folder = try TemporaryFolder()
        model = StitchModel(capture: source, overlays: overlays)
        model.useGlobalShortcuts = false
        model.recordingsFolder = folder.url
        model.countsDownBeforeRecording = false
        model.showsSlate = true
    }

    // Lets the flow's background steps run.
    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // Record Another: the session has a clip, so the last target is reused.
    private func getReady(_ target: LastTarget) async {
        model.items = [.clip(makeClip())]
        flow.lastTarget = target
        flow.startRecording()
        await settle { flow.state != .starting }
    }

    private func startRecording(_ target: LastTarget) async {
        overlays.windowFrames[42] = CGRect(x: 100, y: 100, width: 600, height: 400)
        await getReady(target)
        flow.beginRecording()
        await settle { !source.calls.isEmpty }
        source.send(.started)
    }

    @Test func recordAnotherGoesStraightToReady() async {
        await getReady(notes)
        #expect(flow.state == .ready("“Notes”"))
        #expect(overlays.bar && overlays.isAppHidden && overlays.focusedPID == 4242)
        #expect(overlays.frame == "window")
        #expect(overlays.pill == "Start")
    }

    @Test func aWindowThatsGoneWarnsAndOpensThePicker() async {
        source.found = false
        await getReady(notes)
        #expect(flow.state == .picking)
        #expect(model.warning == "Couldn't find “Notes” anymore. Pick something else to record.")
        #expect(flow.lastTarget == nil)
    }

    @Test func withoutPermissionItAsks() async {
        source.canCapture = false
        await getReady(notes)
        #expect(flow.state == .needsPermission)
        #expect(source.askedForPermission)
    }

    @Test func startRecordsAndShowsThatItsRecording() async {
        await getReady(display)
        flow.beginRecording()
        #expect(flow.state == .starting)
        #expect(overlays.slate)
        #expect(source.calls == ["record"])
        source.send(.started)
        #expect(flow.isCapturing)
        #expect(overlays.frameRecording && overlays.badge)
        #expect(!overlays.slate && overlays.calls.contains("clap"))
        // A display has no room around it for Start or Stop.
        #expect(overlays.pill == nil)
    }

    @Test func countdownCountsThenRecords() async {
        model.countsDownBeforeRecording = true
        await getReady(display)
        flow.beginRecording()
        #expect(flow.state == .countdown(3) && overlays.countdown == 3)
        overlays.tick?()
        #expect(flow.state == .countdown(2) && overlays.countdown == 2)
        overlays.tick?()
        overlays.tick?()
        #expect(flow.state == .starting)
        #expect(overlays.countdown == nil)
        #expect(source.calls == ["record"])
    }

    @Test func cancellingTheCountdownMakesAnAreaEditableAgain() async {
        model.countsDownBeforeRecording = true
        await getReady(area)
        #expect(overlays.editingArea && overlays.frame == nil)
        // The area's Start comes with its editor.
        #expect(overlays.pill == nil)
        flow.beginRecording()
        #expect(!overlays.editingArea && overlays.frame == "area")
        flow.cancelCountdown()
        #expect(flow.state == .ready("the 400×200 area"))
        #expect(overlays.editingArea && overlays.frame == nil && overlays.countdown == nil)
    }

    @Test func anAreaRecordsWhereItWasMoved() async {
        await getReady(area)
        overlays.moveArea?(CGRect(x: 200, y: 300, width: 300, height: 100), screen)
        #expect(flow.state == .ready("the 300×100 area"))
        flow.beginRecording()
        #expect(source.calls == ["record 300×100"])
        source.send(.started)
        #expect(overlays.pill == "Stop")
    }

    @Test func aStartAfterCancellingIsIgnored() async {
        flow.pickTarget()
        flow.useSystemPicker()
        #expect(flow.state == .systemPicker && source.calls == ["pick"])
        flow.cancelRecording()
        source.send(.cancelled)
        #expect(flow.state == .idle)
        source.send(.started)
        #expect(flow.state == .idle && !overlays.bar)
    }

    @Test func quittingMidRecordingFinishesTheClipFirst() async {
        await startRecording(display)
        var quits = 0
        let waits = flow.finishRecordingBeforeQuit { quits += 1 }
        #expect(waits)
        #expect(source.calls.last == "stop" && quits == 0)
        source.send(.finished(nil))
        #expect(quits == 1 && flow.state == .idle)
    }

    @Test func quittingWhileGettingReadyDoesntWait() async {
        await getReady(display)
        let waits = flow.finishRecordingBeforeQuit {}
        #expect(!waits)
    }

    @Test func aFailureCleansUp() async {
        await startRecording(notes)
        source.send(.failed("The disk is full."))
        #expect(flow.state == .idle)
        #expect(model.warning == "Recording failed: The disk is full.")
        #expect(!overlays.bar && overlays.frame == nil && overlays.pill == nil && !overlays.badge && !overlays.isAppHidden)
    }

    @Test func theShortcutStepsThroughTheFlow() async {
        overlays.windowFrames[42] = CGRect(x: 100, y: 100, width: 600, height: 400)
        model.items = [.clip(makeClip())]
        flow.lastTarget = notes
        flow.recordShortcut()
        await settle { flow.state != .starting }
        #expect(flow.state == .ready("“Notes”"))
        flow.recordShortcut()
        await settle { !source.calls.isEmpty }
        #expect(source.calls == ["record"])
        source.send(.started)
        #expect(flow.isCapturing && overlays.pill == "Stop")
        flow.recordShortcut()
        #expect(source.calls.last == "stop")
    }

    @Test func escCancelsWhatsGettingReady() async {
        model.countsDownBeforeRecording = true
        await getReady(display)
        flow.beginRecording()
        flow.escapePressed()
        #expect(flow.state == .ready("the entire screen"))
        flow.escapePressed()
        #expect(flow.state == .idle && !overlays.bar && !overlays.isAppHidden)
    }

    @Test func escEndsAreaSelection() {
        flow.pickTarget()
        flow.selectArea()
        #expect(flow.state == .selectingArea)
        flow.escapePressed()
        #expect(overlays.calls.contains("cancel area selection") && flow.state == .idle)
    }

    @Test func aWindowOffScreenCantStart() async {
        await getReady(notes)
        flow.beginRecording()
        #expect(flow.state == .ready("“Notes”"))
        #expect(flow.readyNote?.hasPrefix("The window isn't on screen.") == true)
        #expect(source.calls.isEmpty)
    }

    @Test func resizingTheWindowFitsItOnlyWhileRecording() async {
        overlays.windowFrames[42] = CGRect(x: 100, y: 100, width: 600, height: 400)
        await getReady(notes)
        overlays.resize?(CGSize(width: 500, height: 300))
        #expect(source.calls.isEmpty)
        flow.beginRecording()
        await settle { !source.calls.isEmpty }
        source.send(.started)
        overlays.resize?(CGSize(width: 640, height: 480))
        #expect(source.calls.last == "fit 640×480")
    }
}
