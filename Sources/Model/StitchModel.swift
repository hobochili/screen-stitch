import AVFoundation
import Carbon.HIToolbox
import os
import Quartz
import ScreenCaptureKit
import SwiftUI

enum EncodeState: Equatable {
    case idle
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
        TextFinder.onRetry = { [weak self] text in
            Task { @MainActor in self?.log(text) }
        }
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
            scheduleSave()
            scheduleSearchUpdate()
        }
    }
    var clips: [Clip] { items.compactMap(\.clip) }
    var titleCards: [TitleCard] { items.compactMap(\.card) }
    // Recordings made or picked up during the session, as opposed to videos added from elsewhere, and every video
    // combined from it. Clear Session can move these to the Trash.
    @ObservationIgnored var sessionRecordings: Set<URL> = [] {
        didSet { scheduleSave() }
    }
    var sessionOutputs: [URL] = [] {
        didSet { scheduleSave() }
    }
    // Which saved video the bottom bar's Saved line shows, when there are several. Nil means the newest.
    var shownVideo: URL?
    // Where the session is kept between launches. Tests use a file of their own, or none.
    @ObservationIgnored var sessionFile = SavedSession.defaultFile
    // The start screen waits while the last session comes back, so it doesn't flash up first.
    private(set) var isRestoring = false
    // Set once a restore has run for half a second, so a quick one never blinks a spinner.
    private(set) var isRestoringSlowly = false
    @ObservationIgnored private var savePending = false
    // Returns where the file went, so it can be put back.
    @ObservationIgnored var moveToTrash: (URL) throws -> URL? = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
    var selection: Set<UUID> = [] {
        didSet {
            quickLookOutput = nil
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }
    }
    var outputSize = (StitchModel.defaults.object(forKey: "outputSize") as? Int).flatMap { OutputSize(rawValue: $0) } ?? .p1080 {
        didSet { StitchModel.defaults.set(outputSize.rawValue, forKey: "outputSize") }
    }
    var quality = StitchModel.defaults.string(forKey: "quality").flatMap { Quality(rawValue: $0) } ?? .standard {
        didSet { StitchModel.defaults.set(quality.rawValue, forKey: "quality") }
    }
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
    var notice: String? {
        didSet {
            removal = nil
            guard let notice else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.notice == notice { self?.notice = nil }
            }
        }
    }
    // The last rows removed, while the notice about them shows, so they can be brought back.
    struct Removal {
        let before: [SessionItem]
        let selection: Set<UUID>
        let removed: Set<UUID>
        let thumbnails: [UUID: NSImage]
        // Original location to where it is in the Trash.
        var trashed: [URL: URL] = [:]
    }

    private(set) var removal: Removal?
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

    // Where the Redact Text list is remembered. Tests keep theirs to themselves.
    nonisolated(unsafe) static var hiddenTextDefaults: UserDefaults? = .standard
    var hiddenText: [HiddenTextEntry] = StitchModel.hiddenTextDefaults?.data(forKey: "hiddenText")
        .flatMap { try? JSONDecoder().decode([HiddenTextEntry].self, from: $0) } ?? [] {
        didSet {
            if let data = try? JSONEncoder().encode(hiddenText) {
                StitchModel.hiddenTextDefaults?.set(data, forKey: "hiddenText")
            }
            clearResult()
            textSearches.values.forEach { $0.forgetFailure() }
            scheduleSearchUpdate()
        }
    }
    // Off keeps the list for another session but redacts nothing.
    var redactsText = StitchModel.hiddenTextDefaults?.object(forKey: "redactsText") as? Bool ?? true {
        didSet {
            StitchModel.hiddenTextDefaults?.set(redactsText, forKey: "redactsText")
            clearResult()
            textSearches.values.forEach { $0.forgetFailure() }
            scheduleSearchUpdate()
        }
    }
    var confirmsClearHiddenText = false
    // Searches for hidden text, by clip file.
    var textSearches: [URL: TextSearch] = [:]
    // What each saved video hid, so it can be checked, and the ones that have been.
    var hiddenRecords: [URL: HiddenRecord] = [:] {
        didSet { scheduleSave() }
    }
    var checkedVideos: Set<URL> = []
    var showsHideTextList = false
    var hiddenTextDraft = ""
    var hiddenTextReview: HiddenTextReview?
    // Set by the review's Redact More Text…, which opens the list once the review has closed.
    var opensHideTextListAfterReview = false
    // Combines and compresses, oldest first: running, waiting and finished.
    var exports: [Export] = []
    var showsExports = false
    // What exports and searches have done, for the Export Log window.
    private(set) var logLines: [LogLine] = []
    // Goes up when the session is cleared, so an export finishing later only shows in the session it came from.
    private(set) var sessionNumber = 0

    private var probing: Set<URL> = []
    private var isManuallyOrdered = false {
        didSet { scheduleSave() }
    }
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var seenFiles: Set<URL> = []
    @ObservationIgnored private var pendingSizes: [URL: Int] = [:]
    @ObservationIgnored private var searchUpdatePending = false
    var isProbing: Bool { !probing.isEmpty }
    var isWatching: Bool { watchFolder != nil }
    var hasBottomBar: Bool {
        !clips.isEmpty || isWatching || warning != nil || notice != nil || state != .idle || recording.isCapturing
            || !savedVideos.isEmpty || !activeHiddenText.isEmpty || isExporting
    }

    // Every video saved this session that's still there, newest first. Unlike existingOutputs, this includes one added
    // back in as a clip.
    var savedVideos: [URL] {
        sessionOutputs.reversed().filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var shownSavedVideo: URL? {
        let videos = savedVideos
        return shownVideo.flatMap { videos.contains($0) ? $0 : nil } ?? videos.first
    }

    // The Saved line takes over from the full card once the list changes, and stays after an error.
    var showsSavedLine: Bool {
        switch state {
        case .idle, .failed: shownSavedVideo != nil
        case .done: false
        }
    }
    nonisolated static let defaultRecordingsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/Screen Stitch", isDirectory: true)

    var isExporting: Bool { exports.contains(where: \.isActive) }
    var runningExport: Export? { exports.first { $0.status == .running } }
    // Files an unfinished export reads from, which can't go to the Trash until it's done.
    var clipsInUse: Set<URL> { Set(exports.filter(\.isActive).flatMap { $0.clips.map(\.url) }) }

    private func inUseWarning(_ clips: [Clip]) -> String {
        clips.count == 1 ? "“\(clips[0].name)” is part of a video that's still being saved. Move it to the Trash once that's done."
            : "\(clips.count) of these clips are part of videos that are still being saved. Move them to the Trash once that's done."
    }
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

    func log(_ text: String) {
        logLines.append(LogLine(date: Date(), text: text))
        if logLines.count > 3000 {
            logLines.removeFirst(logLines.count - 3000)
        }
    }

    func clearLog() {
        logLines = []
    }

    func clearFinishedExports() {
        exports.removeAll { !$0.isActive }
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
        guard let tools else { return }
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

    // Several changes in a row are saved once, after the current event.
    private func scheduleSave() {
        guard !savePending, !isRestoring, sessionFile != nil else { return }
        savePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    private func scheduleSearchUpdate() {
        guard !searchUpdatePending else { return }
        searchUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.searchUpdatePending = false
                self?.updateSearches()
            }
        }
    }

    func saveSession() {
        savePending = false
        guard let sessionFile, !isRestoring else { return }
        let saved = SavedSession(
            items: items.map { item in
                switch item {
                case let .clip(clip): .clip(clip.url)
                case let .card(card): .card(text: card.text, duration: card.duration, isLight: card.isLight, role: card.role)
                }
            },
            isManuallyOrdered: isManuallyOrdered,
            recordings: sessionRecordings.sorted { $0.path < $1.path },
            outputs: sessionOutputs,
            hiddenRecords: Dictionary(uniqueKeysWithValues: hiddenRecords.filter { sessionOutputs.contains($0.key) }.map { ($0.key.path, $0.value) })
        )
        try? saved.save(to: sessionFile)
    }

    // Brings back the session from the last launch, after any videos opened meanwhile. Clips that are gone or can no
    // longer be read are left out. `isRestoring` is set before this returns, so the window's first frame already waits.
    @discardableResult
    func restoreSession() -> Task<Void, Never>? {
        guard let tools, let sessionFile, let saved = SavedSession.load(from: sessionFile) else { return nil }
        isRestoring = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            isRestoringSlowly = isRestoring
        }
        return Task { await bringBack(saved, tools: tools) }
    }

    private func bringBack(_ saved: SavedSession, tools: Tools) async {
        let urls = saved.items.compactMap { if case let .clip(url) = $0 { url } else { nil } }
        let probed = Dictionary(await Prober.probeAll(urls, ffprobe: tools.ffprobe)) { first, _ in first }
        let known = Set(clips.map(\.url))
        var missing: [String] = []
        let restored: [SessionItem] = saved.items.compactMap { item in
            switch item {
            case let .clip(url):
                guard !known.contains(url) else { return nil }
                guard let clip = probed[url] ?? nil else {
                    missing.append(url.lastPathComponent)
                    return nil
                }
                return .clip(clip)
            case let .card(text, duration, isLight, role):
                return .card(TitleCard(text: text, duration: duration, isLight: isLight, role: role))
            }
        }
        items = restored + items
        isManuallyOrdered = saved.isManuallyOrdered
        if !isManuallyOrdered {
            sortClipsKeepingCards()
        }
        sessionRecordings.formUnion(saved.recordings)
        sessionOutputs = saved.outputs + sessionOutputs.filter { !saved.outputs.contains($0) }
        for (path, record) in saved.hiddenRecords ?? [:] {
            hiddenRecords[URL(fileURLWithPath: path)] = record
        }
        isRestoring = false
        isRestoringSlowly = false
        saveSession()
        if !missing.isEmpty {
            warning = "Left out (moved, deleted or can't be opened since last time): \(missing.joined(separator: ", "))"
        }
        for clip in restored.compactMap(\.clip) {
            Task { await loadThumbnail(for: clip) }
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
        guard let folder = watchFolder, !recording.isRecording else { return }
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
        guard let first = items.first else { return false }
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

    // A row's menu acts on the whole selection when that row is part of it, as in the Finder.
    func targets(for id: UUID) -> Set<UUID> {
        selection.contains(id) ? selection : [id]
    }

    var selectionHasClips: Bool {
        clips.contains { selection.contains($0.id) }
    }

    // Takes rows out of the list and leaves their files alone. The notice can undo it, or move recordings made in this
    // session to the Trash after all.
    func remove(_ ids: Set<UUID>) {
        guard let removal = takeOut(ids) else { return }
        notice = "Removed \(describe(removal.removed, in: removal.before)) from the list."
        self.removal = removal
    }

    // Recordings made in this session go straight to the Trash, as files do in the Finder. Videos added from elsewhere
    // weren't made here, so Screen Stitch asks first.
    func trashItems(_ ids: Set<UUID>) {
        let inUse = clipsInUse
        let busy = clips.filter { ids.contains($0.id) && inUse.contains($0.url) }
        guard busy.isEmpty else {
            warning = inUseWarning(busy)
            return
        }
        guard let prompt = trashPrompt(for: ids) else {
            trash(ids)
            return
        }
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: "Remove from List").keyEquivalent = "\r"
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: remove(ids)
        case .alertSecondButtonReturn: trash(ids)
        default: break
        }
    }

    func trashPrompt(for ids: Set<UUID>) -> (title: String, message: String)? {
        let chosen = clips.filter { ids.contains($0.id) }
        let added = chosen.filter { !sessionRecordings.contains($0.url) }
        guard !added.isEmpty else { return nil }
        let title = chosen.count == 1 ? "Move “\(chosen[0].name)” to the Trash?" : "Move \(chosen.count) clips to the Trash?"
        let message = chosen.count == 1 ? "You added this video from elsewhere. Screen Stitch didn't record it."
            : added.count == chosen.count ? "You added these videos from elsewhere. Screen Stitch didn't record them."
            : added.count == 1 ? "1 of the \(chosen.count) clips was added from elsewhere. Screen Stitch didn't record it."
            : "\(added.count) of the \(chosen.count) clips were added from elsewhere. Screen Stitch didn't record them."
        return (title, message + " You can put back anything moved to the Trash.")
    }

    // Moves the clips' files to the Trash and takes their rows, and any title cards chosen with them, out of the list.
    // A clip whose file can't be moved stays.
    func trash(_ ids: Set<UUID>) {
        let inUse = clipsInUse
        let busy = clips.filter { ids.contains($0.id) && inUse.contains($0.url) }
        guard busy.isEmpty else {
            warning = inUseWarning(busy)
            return
        }
        let result = moveFilesToTrash(clips.filter { ids.contains($0.id) })
        let removal = takeOut(ids.subtracting(result.failed.map(\.id)))
        if let removal {
            reportTrashed(removal, result)
        } else if !result.failed.isEmpty {
            warning = "Couldn't move to the Trash: \(result.failed.map(\.name).joined(separator: ", "))"
        }
    }

    // The notice's Move to Trash, for clips just removed from the list.
    func trashRemoved() {
        guard let removal, canTrashRemoved else { return }
        let inUse = clipsInUse
        let busy = removal.before.compactMap(\.clip).filter { removal.removed.contains($0.id) && inUse.contains($0.url) }
        guard busy.isEmpty else {
            warning = inUseWarning(busy)
            return
        }
        let result = moveFilesToTrash(removal.before.compactMap(\.clip).filter { removal.removed.contains($0.id) })
        if result.moved.isEmpty {
            notice = nil
        }
        reportTrashed(removal, result)
    }

    // True when the last removal was only of recordings made in this session, which can go to the Trash without asking.
    var canTrashRemoved: Bool {
        guard let removal, removal.trashed.isEmpty else { return false }
        let removed = removal.before.compactMap(\.clip).filter { removal.removed.contains($0.id) }
        return !removed.isEmpty && removed.allSatisfy { sessionRecordings.contains($0.url) }
    }

    func undoRemoval() {
        guard let removal, removal.trashed.isEmpty else { return }
        restore(removal)
    }

    // Moves the files back out of the Trash and puts their rows back. Any that can't be moved back are left out.
    func putBack() {
        guard let removal, !removal.trashed.isEmpty else { return }
        var failed: Set<URL> = []
        for (original, inTrash) in removal.trashed {
            do {
                try FileManager.default.moveItem(at: inTrash, to: original)
            } catch {
                failed.insert(original)
            }
        }
        restore(removal, leavingOut: failed)
        let names = failed.map(\.lastPathComponent).sorted()
        if names.count == 1 {
            warning = "Couldn't put back \(names[0]). It's still in the Trash."
        } else if names.count > 1 {
            warning = "Couldn't put back \(names.count) clips: \(names.joined(separator: ", ")). They're still in the Trash."
        }
    }

    private func restore(_ removal: Removal, leavingOut missing: Set<URL> = []) {
        notice = nil
        items = removal.before.filter { item in item.clip.map { !missing.contains($0.url) } ?? true }
        thumbnails.merge(removal.thumbnails) { current, _ in current }
        selection = removal.selection
        clearResult()
    }

    private struct TrashResult {
        // Original location to where it is in the Trash, for each file whose new location is known.
        var trashed: [URL: URL] = [:]
        var moved: [Clip] = []
        var failed: [Clip] = []
    }

    private func moveFilesToTrash(_ clips: [Clip]) -> TrashResult {
        var result = TrashResult()
        for clip in clips {
            do {
                if let inTrash = try moveToTrash(clip.url) {
                    result.trashed[clip.url] = inTrash
                }
                result.moved.append(clip)
            } catch {
                result.failed.append(clip)
            }
        }
        return result
    }

    private func reportTrashed(_ removal: Removal, _ result: TrashResult) {
        if !result.moved.isEmpty {
            notice = "Moved \(describe(Set(result.moved.map(\.id)), in: removal.before)) to the Trash."
            // Put Back needs to know where every file went. Without that, the Trash's own Put Back still works.
            if result.trashed.count == result.moved.count {
                var removal = removal
                removal.trashed = result.trashed
                self.removal = removal
            }
        }
        if !result.failed.isEmpty {
            warning = "Couldn't move to the Trash: \(result.failed.map(\.name).joined(separator: ", "))"
        }
    }

    // Removes the rows and, if that empties the selection, selects the row that took the first one's place, or else the
    // one before it.
    private func takeOut(_ ids: Set<UUID>) -> Removal? {
        let before = items
        guard let first = before.firstIndex(where: { ids.contains($0.id) }) else { return nil }
        let removal = Removal(before: before, selection: selection, removed: ids.intersection(before.map(\.id)),
                              thumbnails: thumbnails.filter { ids.contains($0.key) })
        let wasSelected = !selection.isEmpty
        items.removeAll { ids.contains($0.id) }
        for id in ids {
            thumbnails[id] = nil
        }
        if wasSelected, selection.isEmpty, !items.isEmpty {
            selection = [items[min(first, items.count - 1)].id]
        }
        clearResult()
        return removal
    }

    // “Take 3.mov”, the “Before…” title card, 3 clips, or 2 clips and 1 title card.
    private func describe(_ ids: Set<UUID>, in list: [SessionItem]) -> String {
        let chosen = list.filter { ids.contains($0.id) }
        if chosen.count == 1, let item = chosen.first {
            let text = item.card?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return item.clip.map { "“\($0.name)”" } ?? (text.isEmpty ? "the empty title card" : "the “\(text)” title card")
        }
        let clipCount = chosen.filter { $0.clip != nil }.count
        let cardCount = chosen.count - clipCount
        let clipsPart = clipCount == 1 ? "1 clip" : "\(clipCount) clips"
        let cardsPart = cardCount == 1 ? "1 title card" : "\(cardCount) title cards"
        return cardCount == 0 ? clipsPart : clipCount == 0 ? cardsPart : "\(clipsPart) and \(cardsPart)"
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

    // Searches that unfinished exports still need are kept.
    func clear() {
        let needed = clipsInUse
        textSearches.values.filter { !needed.contains($0.url) }.forEach { $0.cancel() }
        textSearches = textSearches.filter { needed.contains($0.key) }
        sessionNumber += 1
        items = []
        thumbnails = [:]
        isManuallyOrdered = false
        warning = nil
        sessionRecordings = []
        sessionOutputs = []
        hiddenRecords = [:]
        checkedVideos = []
        shownVideo = nil
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

    // Each choice says what it moves, so "everything" can't be taken to mean the whole folder. Keep Files comes first.
    var clearPrompt: (title: String, message: String, choices: [(label: String, action: ClearAction)]) {
        let count = clips.count
        let outputs = existingOutputs
        guard count > 0 else {
            let message = outputs.count == 1
                ? "Keep Files leaves the saved video, “\(outputs[0].lastPathComponent)”, where it is. Move Video to Trash moves it."
                : "Keep Files leaves the \(outputs.count) videos saved in this session where they are. Move Videos to Trash moves them."
            return ("Clear this session?", message + " You can put back anything moved to the Trash.",
                    [("Keep Files", .keepFiles), (outputs.count == 1 ? "Move Video to Trash" : "Move Videos to Trash", .moveEverything)])
        }
        let title = isCombined || !outputs.isEmpty ? "Clear this session?"
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
        let theClips = count == 1 ? "the clip" : "the clips"
        if outputs.count == 1 {
            message += " Move Everything to Trash moves \(theClips) and the saved video, “\(outputs[0].lastPathComponent)”."
        } else if outputs.count > 1 {
            message += " Move Everything to Trash moves \(theClips) and the \(outputs.count) videos saved in this session."
        }
        message += (outputs.isEmpty ? "" : " Nothing else is touched.") + " You can put back anything moved to the Trash."
        if clips.contains(where: { clipsInUse.contains($0.url) }) {
            message += " Clips in videos that are still being saved stay where they are."
        }
        var choices: [(label: String, action: ClearAction)] = [("Keep Files", .keepFiles), ("Move Clips to Trash", .moveClips)]
        if !outputs.isEmpty {
            choices.append(("Move Everything to Trash", .moveEverything))
        }
        return (title, message, choices)
    }

    // Ends the session, asking what to do with its files.
    func clearSession() {
        guard !clips.isEmpty || !existingOutputs.isEmpty else {
            clearSession(.keepFiles)
            return
        }
        let prompt = clearPrompt
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        for (index, choice) in prompt.choices.enumerated() {
            let button = alert.addButton(withTitle: choice.label)
            // Return keeps the files, set here rather than left to NSAlert's own default.
            if index == 0 {
                button.keyEquivalent = "\r"
            } else {
                button.hasDestructiveAction = true
            }
        }
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard prompt.choices.indices.contains(choice) else { return }
        clearSession(prompt.choices[choice].action)
    }

    // Only files the session knows about are moved: its clips and the videos combined from them.
    func clearSession(_ action: ClearAction) {
        let all = switch action {
        case .keepFiles: [URL]()
        case .moveClips: clips.map(\.url)
        case .moveEverything: clips.map(\.url) + existingOutputs
        }
        let inUse = clipsInUse
        let files = all.filter { !inUse.contains($0) }
        let kept = all.count - files.count
        var failed: [String] = []
        for file in files {
            do {
                _ = try moveToTrash(file)
            } catch {
                failed.append(file.lastPathComponent)
            }
        }
        clear()
        state = .idle
        let moved = files.count - failed.count
        notice = moved == 0 ? nil : moved == 1 ? "Moved 1 file to the Trash." : "Moved \(moved) files to the Trash."
        if kept > 0 {
            notice = (notice.map { $0 + " " } ?? "") + (kept == 1 ? "Kept 1 clip that's still being saved." : "Kept \(kept) clips that are still being saved.")
        }
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

    // Title cards and boxes over hidden text have to be drawn into the video, so a session with either can't be joined
    // as is. Until the search is done, hidden text counts as found.
    var canCombineWithoutCompressing: Bool {
        titleCards.isEmpty && EncodeJob.canJoin(clips) && clips.allSatisfy { hiddenTextTracks(for: $0)?.isEmpty == true }
    }

    // Clips whose files were moved, renamed or deleted after they were added, named so they can be found.
    var missingClipsProblem: String? {
        let missing = clips.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.map(\.name)
        if missing.count == 1 {
            return "\(missing[0]) can't be found. It may have been moved, renamed or deleted. Remove it from the list, or add it again from where it is now."
        } else if missing.count > 1 {
            return "\(missing.count) clips can't be found: \(missing.joined(separator: ", ")). They may have been moved, renamed or deleted. Remove them from the list, or add them again from where they are now."
        }
        return nil
    }

    func chooseOutputAndEncode(compressing: Bool = true) {
        guard let first = clips.first else { return }
        if let missingClipsProblem {
            state = .failed(missingClipsProblem)
            return
        }
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

    // Adds an export of the session as it is now to the queue. The session can change straight away.
    func encode(to output: URL, compressing: Bool = true) {
        guard tools != nil, !clips.isEmpty else { return }
        if let missingClipsProblem {
            state = .failed(missingClipsProblem)
            return
        }
        guard !exports.contains(where: { $0.isActive && $0.output == output }) else {
            state = .failed("“\(output.lastPathComponent)” is already being saved. Choose a different name, or wait until it's done.")
            return
        }
        // A clip replaced since it was searched is searched again, and one whose search failed gets another try.
        for clip in clips {
            textSearches[clip.url]?.checkFile()
            textSearches[clip.url]?.forgetFailure()
        }
        let texts = activeHiddenText
        // Joining as is can't cover text, so it's only for clips where none was found.
        let export = Export(output: output, items: items, size: outputSize, quality: quality, texts: texts,
                            joins: !compressing && canCombineWithoutCompressing, session: sessionNumber)
        exports.append(export)
        state = .idle
        let clipCount = export.clips.count == 1 ? "1 clip" : "\(export.clips.count) clips"
        log("Queued “\(export.name)”: \(clipCount), \(formatDuration(export.duration))"
            + (texts.isEmpty ? "" : ", redacting \(texts.count == 1 ? "1 text" : "\(texts.count) texts")"))
        startNextExport()
    }

    // One at a time, so each export has the whole Mac.
    private func startNextExport() {
        guard runningExport == nil, let next = exports.first(where: { $0.status == .waiting }) else { return }
        next.status = .running
        next.startedAt = Date()
        next.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Saving a video")
        // Standardizing only strips /private from paths that exist, so do it on the folder.
        seenFiles.insert(next.output.deletingLastPathComponent().standardizedFileURL.appendingPathComponent(next.output.lastPathComponent))
        log("Started “\(next.name)”")
        if !next.texts.isEmpty, !next.joins {
            redact(next)
        } else {
            startFFmpeg(next)
        }
        updateSearches()
    }

    private func setStage(_ export: Export, _ stage: String) {
        guard stage != export.stage else { return }
        if let previous = export.stage {
            log("“\(export.name)”: \(previous) took \(formatDuration(Date().timeIntervalSince(export.stageStartedAt)))")
        }
        export.stage = stage
        export.stageStartedAt = Date()
        log("“\(export.name)”: \(stage)")
    }

    // Finishes looking for the text, writes a covered copy of each clip it was found in, then hands the copies to
    // FFmpeg in place of those clips. Searching, covering and compressing share one progress bar.
    private func redact(_ export: Export) {
        let stop = CancelFlag()
        export.coverStop = stop
        let texts = export.texts
        let clips = export.clips
        let searchShare = clips.contains { needsSearch($0, for: texts) } ? 0.4 : 0
        Task {
            var covered: [UUID: Clip] = [:]
            var redacting: String?
            var failure: String?
            do {
                updateSearches()
                let total = max(clips.reduce(0) { $0 + $1.duration }, 0.001)
                while !export.cancelled, clips.contains(where: { needsSearch($0, for: texts) }) {
                    let left = clips.filter { needsSearch($0, for: texts) }.reduce(0) { $0 + $1.duration }
                    let searching = clips.first { textSearches[$0.url]?.isBusy == true }
                    let current = searching.map { (textSearches[$0.url]?.progress ?? 0) * $0.duration } ?? 0
                    export.progress = searchShare * min(max((total - left + current) / total, 0), 1)
                    if let searching, let index = clips.firstIndex(of: searching) {
                        setStage(export, clips.count == 1 ? "Looking through the clip" : "Looking through clip \(index + 1) of \(clips.count)")
                    } else {
                        setStage(export, "Waiting to look for text")
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if export.cancelled { throw CancellationError() }
                if let failed = clips.first(where: { textSearches[$0.url]?.failure != nil }), let reason = textSearches[failed.url]?.failure {
                    throw ProbeError("Couldn't look for text in “\(failed.name)”. \(reason) Remove the clip from the list, or uncheck the text to redact, then combine again.")
                }
                var tracks: [UUID: [TextTrack]] = [:]
                for clip in clips {
                    guard let found = hiddenTextTracks(for: clip, texts: texts) else {
                        throw ProbeError("Couldn't look for text in “\(clip.name)”. Combine again to look once more.")
                    }
                    if !found.isEmpty { tracks[clip.id] = found }
                }
                export.record = hiddenRecord(items: export.items, texts: texts, tracks: tracks)

                let coverShare = tracks.isEmpty ? 0 : 0.2
                let coverTotal = max(clips.filter { tracks[$0.id] != nil }.reduce(0) { $0 + $1.duration }, 0.001)
                var done = 0.0
                for clip in clips {
                    guard let found = tracks[clip.id] else { continue }
                    redacting = clip.name
                    setStage(export, "Redacting text in “\(clip.name)”")
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("screen-stitch-covered-\(UUID().uuidString).mov")
                    export.coverCopies.append(copy)
                    let before = done
                    try await TextCover.write(clip.url, covering: found, to: copy, progress: { value in
                        Task { @MainActor in export.progress = searchShare + coverShare * (before + value * clip.duration) / coverTotal }
                    }, stop: stop, pause: export.coverPause)
                    done += clip.duration
                    // Read back rather than assumed, since the copy only has the streams AVFoundation could carry over.
                    guard let tools, let copied = await Prober.probeAll([copy], ffprobe: tools.ffprobe).first?.1 else {
                        throw ProbeError("Couldn't read “\(clip.name)” after redacting its text.")
                    }
                    covered[clip.id] = copied
                }
                // Cancel can land while the last copy is finishing.
                if export.cancelled { throw CancellationError() }
                export.progressBase = searchShare + coverShare
            } catch {
                export.coverCopies.forEach { try? FileManager.default.removeItem(at: $0) }
                export.coverCopies = []
                export.record = nil
                if !(export.cancelled || error is CancellationError) {
                    let place = redacting.map { " in “\($0)”" } ?? ""
                    failure = (error as? ProbeError)?.errorDescription ?? "Couldn't redact the text\(place): \(error.localizedDescription)"
                }
            }
            export.coverStop = nil
            if let failure {
                end(export, .failed(failure))
            } else if export.cancelled {
                end(export, .cancelled)
            } else {
                let copies = export.coverCopies
                export.coverCopies = []
                startFFmpeg(export, replacing: covered, temporaryFiles: copies)
            }
        }
    }

    private func startFFmpeg(_ export: Export, replacing covered: [UUID: Clip] = [:], temporaryFiles copies: [URL] = []) {
        guard let tools else { return }
        let temporary = FileManager.default.temporaryDirectory
        let clips = export.clips
        var job: EncodeJob
        do {
            if export.joins {
                job = EncodeJob(clips: clips, size: export.size, quality: export.quality, output: export.output)
                let list = temporary.appendingPathComponent("screen-stitch-\(UUID().uuidString).txt")
                try job.concatList.write(to: list, atomically: true, encoding: .utf8)
                job.mode = .join(list: list)
                job.temporaryFiles = [list]
            } else {
                let (width, height, _) = EncodeJob.canvas(for: clips, size: export.size)
                var images: [URL] = []
                let segments: [EncodeJob.Segment] = try export.items.map { item in
                    switch item {
                    case let .clip(clip):
                        return .clip(covered[clip.id] ?? clip)
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
                job = EncodeJob(segments: segments, size: export.size, quality: export.quality, output: export.output)
                job.temporaryFiles = images + copies
            }
        } catch {
            copies.forEach { try? FileManager.default.removeItem(at: $0) }
            end(export, .failed("Couldn't \(clips.count == 1 ? "compress the clip" : "combine the clips"): \(error.localizedDescription)"))
            return
        }
        setStage(export, export.joins ? "Joining" : clips.count == 1 ? "Compressing" : "Combining and compressing")
        let run = FFmpegRun()
        let base = export.progressBase
        do {
            try run.start(
                ffmpeg: tools.ffmpeg,
                arguments: job.arguments,
                duration: job.duration,
                onProgress: { value in Task { @MainActor in export.progress = base + (1 - base) * value } },
                onExit: { status, errors in Task { @MainActor in self.finish(export, status: status, errors: errors) } }
            )
        } catch {
            job.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            end(export, .failed("Couldn't start FFmpeg: \(error.localizedDescription)"))
            return
        }
        if recording.isCapturing {
            run.setBackground(true)
        }
        export.run = run
        export.job = job
        export.progress = base
    }

    func cancel() {
        if let runningExport {
            cancel(runningExport)
        }
    }

    func cancel(_ export: Export) {
        switch export.status {
        case .waiting:
            end(export, .cancelled)
        case .running:
            export.cancelled = true
            export.coverStop?.set()
            export.run?.forceStop()
        default:
            break
        }
    }

    func abortForQuit() {
        textSearches.values.forEach { $0.cancel() }
        for export in exports where export.status == .running {
            export.cancelled = true
            export.coverStop?.set()
            export.coverCopies.forEach { try? FileManager.default.removeItem(at: $0) }
            if let run = export.run, let job = export.job {
                run.forceStopAndWait()
                removePartialOutput(of: export, job)
            }
        }
    }

    // A failed or cancelled run leaves a partial file, unless FFmpeg stopped before writing; then any file of that name
    // is one the user chose to replace, and it's kept.
    private func removePartialOutput(of export: Export, _ job: EncodeJob) {
        job.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        let modified = try? job.output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let modified, modified >= (export.startedAt ?? .distantPast).addingTimeInterval(-1) {
            try? FileManager.default.removeItem(at: job.output)
        }
    }

    private func finish(_ export: Export, status: Int32, errors: String) {
        guard let job = export.job else { return }
        export.run = nil
        export.job = nil
        job.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        if export.cancelled {
            removePartialOutput(of: export, job)
            end(export, .cancelled)
        } else if status == 0 {
            let bytes = Int64((try? job.output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            export.progress = 1
            // An export from a session that has since been cleared isn't added to the new one.
            if export.session == sessionNumber {
                let output = job.output.standardizedFileURL
                // Saving over an earlier video makes it the newest again.
                sessionOutputs.removeAll { $0 == output }
                sessionOutputs.append(output)
                hiddenRecords[output] = export.record
                checkedVideos.remove(output)
                shownVideo = nil
                state = .done(output: job.output, outputBytes: bytes, inputBytes: export.clips.reduce(0) { $0 + $1.fileSize })
                Task {
                    let image = await Self.thumbnail(of: job.output, duration: job.duration)
                    if case .done(job.output, _, _) = state {
                        outputThumbnail = image
                    }
                }
            }
            NSApp?.requestUserAttention(.informationalRequest)
            end(export, .done(outputBytes: bytes))
        } else {
            removePartialOutput(of: export, job)
            let action = job.clips.count == 1 ? "compress the clip" : "combine the clips"
            end(export, .failed(errors.isEmpty
                ? "Couldn't \(action) (FFmpeg exited with status \(status))."
                : "Couldn't \(action). FFmpeg reported:\n\(errors)"))
        }
    }

    private func end(_ export: Export, _ status: Export.Status) {
        let took = export.startedAt.map { " after \(formatDuration(Date().timeIntervalSince($0)))" } ?? ""
        export.status = status
        export.stage = nil
        if let activity = export.activity {
            ProcessInfo.processInfo.endActivity(activity)
            export.activity = nil
        }
        switch status {
        case .done: log("Saved “\(export.name)”\(took)")
        case let .failed(message):
            log("“\(export.name)” failed\(took): \(message)")
            if export.session == sessionNumber {
                state = .failed(message)
            }
        case .cancelled: log("Canceled “\(export.name)”\(took)")
        default: break
        }
        startNextExport()
        updateSearches()
    }

    // Any change to the list ends what the full card and a removal's Undo describe.
    private func clearResult() {
        state = .idle
        if removal != nil {
            notice = nil
        }
    }
}
