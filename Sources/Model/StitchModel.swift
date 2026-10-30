import AVFoundation
import Carbon.HIToolbox
import os
import Quartz
import ScreenCaptureKit
import SwiftUI

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
    // Picking what to record, and recording it.
    @ObservationIgnored private(set) var recording: RecordingFlow!

    // Tests pass stand-ins for ScreenCaptureKit and the screen.
    init(capture: CaptureSource? = nil, overlays: RecordingOverlays? = nil) {
        recording = RecordingFlow(model: self, source: capture ?? LiveCaptureSource(),
                                  overlays: overlays ?? LiveRecordingOverlays(model: self))
    }
    // The session is the list of clips and title cards, and the video made from them. The last target only matters
    // while recording a series, so a session without clips forgets it.
    var items: [SessionItem] = [] {
        didSet {
            if clips.isEmpty {
                recording.lastTarget = nil
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
    var thumbnails: [UUID: NSImage] = [:]
    var showsSlate = StitchModel.defaults.object(forKey: "showsSlate") as? Bool ?? true {
        didSet { StitchModel.defaults.set(showsSlate, forKey: "showsSlate") }
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
    private var isManuallyOrdered = false
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var seenFiles: Set<URL> = []
    @ObservationIgnored private var pendingSizes: [URL: Int] = [:]
    @ObservationIgnored private var run: FFmpegRun?
    @ObservationIgnored private var job: EncodeJob?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    var isProbing: Bool { !probing.isEmpty }
    var isWatching: Bool { watchFolder != nil }
    var hasBottomBar: Bool {
        !clips.isEmpty || isWatching || warning != nil || notice != nil || state != .idle || recording.isCapturing
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

    // Also run when the app becomes active, since a shortcut may have been turned off in System Settings meanwhile.
    func updateGlobalShortcuts() {
        recording.updateEscapeKey()
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
                self?.recording.recordShortcut()
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

    func showApp() {
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" }
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
        guard let folder = watchFolder, !isEncoding, !recording.isRecording else { return }
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
