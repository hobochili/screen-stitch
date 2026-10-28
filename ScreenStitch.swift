import AppKit
import Carbon.HIToolbox
import AVFoundation
import AVKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum Launcher {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--cli" {
            CLI.run(Array(arguments.dropFirst()))
        } else {
            ScreenStitchApp.main()
        }
    }
}

struct ScreenStitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Screen Stitch", id: "main") {
            ContentView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                FileCommands(model: appDelegate.model)
            }
            CommandMenu("Record") {
                RecordCommands(model: appDelegate.model)
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

struct FileCommands: View {
    let model: StitchModel

    var body: some View {
        let busy = model.isEncoding || model.isRecording || model.tools == nil
        Button("Add Videos…") { model.chooseFiles() }
            .keyboardShortcut("o")
            .disabled(busy)
        Divider()
        Button("Sort by Date") { model.sortByDate() }
            .disabled(busy || model.clips.count < 2)
        Button("Clear List…") { model.confirmClear() }
            .disabled(busy || model.clips.isEmpty)
    }
}

struct RecordCommands: View {
    let model: StitchModel

    var body: some View {
        let busy = model.isEncoding || model.tools == nil
        Button(model.isCapturing ? "Stop Recording" : "Record Screen") { model.toggleRecording() }
            .keyboardShortcut("r")
            .disabled(busy || (model.isRecording && !model.isCapturing))
        Button("Record Something Else…") { model.pickTarget() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(busy || model.isRecording)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = StitchModel()
    private var terminationSignal: DispatchSourceSignal?

    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls)
    }

    // Quit when the main window closes. AppKit's "terminate after last window closed" (SwiftUI turns it on for
    // single-Window apps) also fires when the recording controls go away while the window is hidden, which quit
    // the app on Stop.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            guard (notification.object as? NSWindow)?.identifier?.rawValue == "main" else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }

        // `build.sh --install` sends SIGTERM; quit the normal way so an export in progress is cleaned up.
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApp.terminate(nil) }
        terminationSignal?.resume()

        model.updateGlobalShortcuts()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.abortForQuit()
    }
}

// MARK: - Clips and settings

struct Clip: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let date: Date
    let duration: Double
    let width: Int
    let height: Int
    let videoStream: Int
    let audioStreams: Int
    let fileSize: Int64

    var name: String { url.lastPathComponent }

    static func chronological(_ a: Clip, _ b: Clip) -> Bool {
        a.date != b.date ? a.date < b.date : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

enum OutputSize: Int, CaseIterable, Identifiable {
    case original = 0
    case p1440 = 1440
    case p1080 = 1080
    case p720 = 720

    var id: Int { rawValue }
    var label: String { self == .original ? "Original" : "\(rawValue)p" }

    init?(argument: String) {
        let value = argument.lowercased()
        if value == "original" {
            self = .original
        } else if let height = Int(value.hasSuffix("p") ? String(value.dropLast()) : value), let size = OutputSize(rawValue: height) {
            self = size
        } else {
            return nil
        }
    }
}

enum Quality: String, CaseIterable, Identifiable {
    case high = "High"
    case standard = "Standard"
    case small = "Smaller File"

    var id: String { rawValue }

    init?(argument: String) {
        switch argument.lowercased() {
        case "high": self = .high
        case "standard": self = .standard
        case "small": self = .small
        default: return nil
        }
    }

    var crf: Int {
        switch self {
        case .high: 20
        case .standard: 23
        case .small: 28
        }
    }
}

struct Tools {
    let ffmpeg: URL
    let ffprobe: URL

    // GUI apps don't inherit the shell PATH.
    static func locate() -> Tools? {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"] {
            let ffmpeg = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
            let ffprobe = URL(fileURLWithPath: directory).appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: ffmpeg.path),
               FileManager.default.isExecutableFile(atPath: ffprobe.path) {
                return Tools(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }
        return nil
    }
}

// MARK: - Probing

struct ProbeError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

enum Prober {
    private struct Output: Decodable {
        struct Stream: Decodable {
            let codec_type: String?
            let width: Int?
            let height: Int?
            let disposition: [String: Int]?
            let side_data_list: [SideData]?
        }

        struct SideData: Decodable {
            let rotation: Double?
        }

        struct Format: Decodable {
            let duration: String?
            let tags: [String: String]?
        }

        let streams: [Stream]
        let format: Format
    }

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let appleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    static func probeAll(_ urls: [URL], ffprobe: URL) async -> [(URL, Clip?)] {
        await withTaskGroup(of: (URL, Clip?).self) { group in
            for url in urls {
                group.addTask { (url, try? probe(url, ffprobe: ffprobe)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    static func probe(_ url: URL, ffprobe: URL) throws -> Clip {
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, let info = try? JSONDecoder().decode(Output.self, from: data) else {
            throw ProbeError("not a readable video")
        }
        let videos = info.streams.filter { $0.codec_type == "video" }
        guard let videoIndex = videos.firstIndex(where: { $0.disposition?["attached_pic"] != 1 }),
              let width = videos[videoIndex].width, let height = videos[videoIndex].height, width > 0, height > 0 else {
            throw ProbeError("no video track")
        }
        guard let duration = info.format.duration.flatMap(Double.init), duration > 0 else {
            throw ProbeError("unknown duration")
        }

        let rotation = Int(videos[videoIndex].side_data_list?.compactMap(\.rotation).first ?? 0)
        let sideways = abs(rotation) % 180 == 90
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        return Clip(
            url: url,
            date: recordingDate(info.format.tags ?? [:], url: url),
            duration: duration,
            width: sideways ? height : width,
            height: sideways ? width : height,
            videoStream: videoIndex,
            audioStreams: info.streams.filter { $0.codec_type == "audio" }.count,
            fileSize: Int64(fileSize)
        )
    }

    private static func recordingDate(_ tags: [String: String], url: URL) -> Date {
        if let value = tags["com.apple.quicktime.creationdate"], let date = appleFormatter.date(from: value) {
            return date
        }
        if let value = tags["creation_time"], let date = utcFormatter.date(from: String(value.prefix(19))),
           date > Date(timeIntervalSince1970: 0) {
            return date
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }
}

// MARK: - Encoding

struct EncodeJob {
    let clips: [Clip]
    let size: OutputSize
    let quality: Quality
    let output: URL

    var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    // The largest clip sets the frame; the size cap applies to its short side so portrait video works too.
    static func canvas(for clips: [Clip], size: OutputSize) -> (width: Int, height: Int) {
        guard let largest = clips.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return (0, 0) }
        var width = Double(largest.width)
        var height = Double(largest.height)
        if size != .original, min(width, height) > Double(size.rawValue) {
            let scale = Double(size.rawValue) / min(width, height)
            width *= scale
            height *= scale
        }
        return (even(width), even(height))
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }

    var arguments: [String] {
        let (width, height) = Self.canvas(for: clips, size: size)
        let hasAudio = clips.contains { $0.audioStreams > 0 }
        let audioFormat = "asetpts=PTS-STARTPTS,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"

        var inputs = clips.flatMap { ["-i", $0.url.path] }
        var filters: [String] = []
        var segments = ""
        var nextInput = clips.count

        for (index, clip) in clips.enumerated() {
            filters.append(
                "[\(index):v:\(clip.videoStream)]setpts=PTS-STARTPTS,"
                    + "scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,"
                    + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[v\(index)]"
            )
            segments += "[v\(index)]"
            guard hasAudio else { continue }

            switch clip.audioStreams {
            case 0:
                inputs += ["-f", "lavfi", "-t", String(format: "%.3f", clip.duration), "-i", "anullsrc=r=48000:cl=stereo"]
                filters.append("[\(nextInput):a]\(audioFormat)[a\(index)]")
                nextInput += 1
            case 1:
                filters.append("[\(index):a:0]\(audioFormat)[a\(index)]")
            default:
                let streams = (0..<clip.audioStreams).map { "[\(index):a:\($0)]" }.joined()
                filters.append("\(streams)amix=inputs=\(clip.audioStreams):duration=longest:normalize=0,\(audioFormat)[a\(index)]")
            }
            segments += "[a\(index)]"
        }
        filters.append("\(segments)concat=n=\(clips.count):v=1:a=\(hasAudio ? 1 : 0)[v]\(hasAudio ? "[a]" : "")")

        return ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
            + inputs
            + ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]"]
            + (hasAudio ? ["-map", "[a]", "-c:a", "aac", "-b:a", "128k"] : [])
            + ["-c:v", "libx264", "-preset", "medium", "-crf", String(quality.crf), "-fps_mode", "vfr"]
            + ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
    }
}

final class FFmpegRun: @unchecked Sendable {
    private final class LineBuffer: @unchecked Sendable {
        private var pending = ""

        func append(_ data: Data) -> [String] {
            pending += String(decoding: data, as: UTF8.self)
            var lines = pending.components(separatedBy: "\n")
            pending = lines.removeLast()
            return lines
        }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    private let process = Process()

    func start(
        ffmpeg: URL,
        arguments: [String],
        duration: Double,
        onProgress: @escaping @Sendable (Double) -> Void,
        onExit: @escaping @Sendable (Int32, String) -> Void
    ) throws {
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = ffmpeg
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        let lines = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in lines.append(data) where line.hasPrefix("out_time_us=") {
                if let micros = Double(line.dropFirst("out_time_us=".count)), duration > 0 {
                    onProgress(min(max(micros / 1_000_000 / duration, 0), 1))
                }
            }
        }

        let errors = DataBox()
        let errorsRead = DispatchGroup()
        errorsRead.enter()
        process.terminationHandler = { process in
            errorsRead.wait()
            let tail = String(decoding: errors.data, as: UTF8.self)
                .split(separator: "\n")
                .suffix(12)
                .joined(separator: "\n")
            onExit(process.terminationStatus, tail)
        }

        do {
            try process.run()
        } catch {
            errorsRead.leave()
            throw error
        }
        DispatchQueue.global().async {
            errors.data = stderr.fileHandleForReading.readDataToEndOfFile()
            errorsRead.leave()
        }
    }

    // SIGTERM would make ffmpeg finish the faststart rewrite of a file we're about to delete.
    func forceStop() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func forceStopAndWait() {
        forceStop()
        process.waitUntilExit()
    }
}

// MARK: - Recording

final class Recorder: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate,
    @unchecked Sendable {
    enum Event {
        case started
        case finished(URL?)
        case cancelled
        case failed(String)
    }

    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return formatter
    }()

    private let folder: URL
    private let microphone: Bool
    private let onEvent: @Sendable (Event) -> Void
    private let frames = DispatchQueue(label: "screen-stitch.frames")
    private let lock = NSLock()
    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private var output: URL?
    private var ended = false

    init(folder: URL, microphone: Bool, onEvent: @escaping @Sendable (Event) -> Void) {
        self.folder = folder
        self.microphone = microphone
        self.onEvent = onEvent
    }

    func pick() {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        configuration.allowsChangingSelectedContent = false
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func stop() {
        lock.withLock { stream }?.stopCapture { _ in }
    }

    func cancel() {
        end(.cancelled)
    }

    // `area` is a region of a display, in points from its top-left corner.
    func record(_ filter: SCContentFilter, area: CGRect? = nil) {
        start(filter, area: area)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        end(.cancelled)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard lock.withLock({ self.stream == nil }) else { return }
        start(filter)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        end(.failed(error.localizedDescription))
    }

    // The floating controls are marked unshareable; with Screen Recording permission, display captures also
    // exclude this app outright, which covers macOS versions that don't honor that flag.
    private func start(_ picked: SCContentFilter, area: CGRect? = nil) {
        let points = area?.size ?? picked.contentRect.size
        let size = CGSize(width: points.width * CGFloat(picked.pointPixelScale), height: points.height * CGFloat(picked.pointPixelScale))
        guard #available(macOS 15.2, *), picked.style == .display, CGPreflightScreenCaptureAccess(),
              let display = picked.includedDisplays.first else {
            record(picked, size: size, area: area)
            return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [self] content, _ in
            let ours = content?.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier } ?? []
            let filter = ours.isEmpty ? picked : SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
            record(filter, size: size, area: area)
        }
    }

    private func record(_ filter: SCContentFilter, size: CGSize, area: CGRect?) {
        // H.264 tops out at 4096 pixels; screencapture downscales large displays the same way.
        let fit = min(1, 4096 / max(size.width, size.height))
        let width = size.width
        let height = size.height
        let configuration = SCStreamConfiguration()
        configuration.width = Int(width * fit / 2) * 2
        configuration.height = Int(height * fit / 2) * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        configuration.captureMicrophone = microphone
        if let area {
            configuration.sourceRect = area
        }

        let url = folder.appendingPathComponent("Screen Stitch \(Self.fileDate.string(from: Date())).mov")
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264
        let recording = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
            try stream.addRecordingOutput(recording)
        } catch {
            end(.failed(error.localizedDescription))
            return
        }
        lock.withLock {
            self.stream = stream
            self.recording = recording
            self.output = url
        }
        stream.startCapture { [self] error in
            if let error {
                end(.failed(error.localizedDescription))
            } else {
                onEvent(.started)
            }
        }
    }

    // Stopped from the system's screen-sharing menu, or the recorded window closed. The recording output
    // normally finalizes the file and reports it; this covers the case where it doesn't.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            let url = lock.withLock { output }
            end(.finished(url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        end(.failed(error.localizedDescription))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        end(.finished(lock.withLock { output }))
    }

    private func end(_ event: Event) {
        let first = lock.withLock {
            defer { ended = true }
            return !ended
        }
        guard first else { return }
        if case .failed = event {
            stop()
        }
        onEvent(event)
        DispatchQueue.main.async { [self] in
            SCContentSharingPicker.shared.remove(self)
            SCContentSharingPicker.shared.isActive = false
        }
    }
}

// A floating bar that stays above every window and Space: Start/Cancel once something is picked, then the timer
// and Stop. The menu bar item mirrors its main action.
@MainActor
final class RecordingControls: NSObject {
    private final class HostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let panel: NSPanel
    private let content: NSView
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var model: StitchModel?

    init(model: StitchModel) {
        self.model = model
        let content = HostingView(rootView: RecordingBar().environment(model))
        let size = content.fittingSize
        content.frame.size = size
        content.autoresizingMask = [.width, .height]
        self.content = content
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        // As the window's content view, a hosting view resizes the window from its left edge whenever the bar
        // changes; inside a plain container, refresh() sizes it around the center instead.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(content)
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.sharingType = .none
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()

        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(menuBarClicked)
        refresh()
    }

    // Resizes around the bar's current top center after the state changes what it shows. A detached hosting
    // view measures it, since the mounted one reports its current frame.
    func refresh() {
        guard let model else { return }
        let size = NSHostingView(rootView: RecordingBar().environment(model)).fittingSize
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        let capturing = model.isCapturing
        item.button?.image = NSImage(systemSymbolName: capturing ? "stop.circle.fill" : "record.circle", accessibilityDescription: nil)
        item.button?.title = capturing ? "Stop Recording" : model.recordingState == .starting ? "Starting…" : "Start Recording"
    }

    func setHidden(_ hidden: Bool) {
        if hidden {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func menuBarClicked() {
        model?.primaryRecordingAction()
    }

    func remove() {
        panel.orderOut(nil)
        NSStatusBar.system.removeStatusItem(item)
    }
}

struct RecordingBar: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            switch model.recordingState {
            case let .ready(title):
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red.opacity(0.4))
                        .frame(width: 10, height: 10)
                    Text(verbatim: "Ready to record \(title)")
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 280, alignment: .leading)
                }
                .padding(.leading, 6)
                .windowDragHandle()
                Button {
                    model.recordMicrophone.toggle()
                } label: {
                    Image(systemName: model.recordMicrophone ? "mic.fill" : "mic.slash")
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.recordMicrophone ? .primary : .secondary)
                .help(model.recordMicrophone ? "Microphone on. Click to turn it off." : "Microphone off. Click to turn it on.")
                if model.isAreaReady {
                    Button("Adjust…") { model.adjustArea() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Move or resize the area")
                }
                Button("Change…") { model.changeTarget() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Pick a different window, display or area")
                Button("Cancel") { model.cancelReady() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                pill("Start", systemImage: "record.circle") { model.beginRecording() }
                    .help(model.useGlobalShortcuts ? "Start recording (⌃⌥⌘R from any app)" : "Start recording")
            case .starting:
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 6)
                Text("Starting…")
                    .font(.body.weight(.medium))
                    .padding(.trailing, 6)
            case let .recording(since):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(since)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                            .opacity(Int(elapsed) % 2 == 0 ? 1 : 0.35)
                        Text(verbatim: "Recording \(formatDuration(elapsed))")
                            .font(.body.monospacedDigit().weight(.medium))
                    }
                }
                .padding(.leading, 6)
                .windowDragHandle()
                pill("Stop", systemImage: "stop.fill") { model.stopRecording() }
                    .help(model.useGlobalShortcuts ? "Stop recording (⌃⌥⌘R from any app)" : "Stop recording")
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
    }

    // A custom style because prominent buttons turn gray in a panel that never becomes key.
    private func pill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.red, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func windowDragHandle() -> some View {
        contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .help("Drag to move")
    }
}

// A dashed outline just outside the area being recorded, so it never shows up in the recording itself.
@MainActor
final class AreaOutline {
    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
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

    init(around rect: CGRect) {
        window = NSWindow(contentRect: rect.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.canHide = false
        window.sharingType = .none
        window.contentView = OutlineView()
        window.orderFrontRegardless()
    }

    func remove() {
        window.orderOut(nil)
    }
}

// Dims every screen and lets the user drag out a rectangle, which is used as soon as they let go. Given an existing
// area instead, it lets them move or resize it until they press Return, double-click or click Done. Reports the screen
// and the rectangle in that screen's coordinates (points, bottom-left origin), or nil if they press Esc.
@MainActor
final class AreaSelector {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        enum Handle {
            case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
        }

        var onBegin: (() -> Void)?
        var onConfirm: ((CGRect) -> Void)?
        var confirmsOnRelease = true
        private(set) var selection: CGRect?
        private var drag: (handle: Handle?, origin: CGPoint, original: CGRect?)?
        private let confirmButton = NSButton(title: "Done", target: nil, action: nil)
        private static let minimumSize: CGFloat = 40

        override init(frame: NSRect) {
            super.init(frame: frame)
            confirmButton.bezelStyle = .push
            confirmButton.controlSize = .large
            confirmButton.keyEquivalent = "\r"
            confirmButton.target = self
            confirmButton.action = #selector(confirm)
            confirmButton.isHidden = true
            addSubview(confirmButton)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func select(_ rect: CGRect) {
            selection = rect
            placeConfirmButton(near: rect)
            needsDisplay = true
        }

        func clear() {
            selection = nil
            drag = nil
            confirmButton.isHidden = true
            needsDisplay = true
        }

        @objc func confirm() {
            if let selection {
                onConfirm?(selection)
            }
        }

        override func mouseMoved(with event: NSEvent) {
            cursor(for: handle(at: convert(event.locationInWindow, from: nil))).set()
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if event.clickCount == 2, let selection, selection.contains(point) {
                confirm()
                return
            }
            onBegin?()
            window?.makeKey()
            if let handle = handle(at: point) {
                drag = (handle, point, selection)
            } else {
                drag = (nil, point, nil)
                selection = nil
            }
            confirmButton.isHidden = true
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let drag else { return }
            let point = convert(event.locationInWindow, from: nil)
            if let handle = drag.handle, let original = drag.original {
                selection = adjusted(original, by: CGSize(width: point.x - drag.origin.x, height: point.y - drag.origin.y), handle: handle)
                (handle == .move ? NSCursor.closedHand : cursor(for: handle)).set()
            } else {
                let rect = CGRect(
                    x: min(drag.origin.x, point.x), y: min(drag.origin.y, point.y),
                    width: abs(point.x - drag.origin.x), height: abs(point.y - drag.origin.y)
                )
                selection = rect.intersection(bounds).integral
            }
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            drag = nil
            if let selection, selection.width >= Self.minimumSize, selection.height >= Self.minimumSize {
                if confirmsOnRelease {
                    onConfirm?(selection)
                    return
                }
                placeConfirmButton(near: selection)
            } else {
                clear()
            }
            cursor(for: handle(at: convert(event.locationInWindow, from: nil))).set()
            needsDisplay = true
        }

        private func adjusted(_ original: CGRect, by delta: CGSize, handle: Handle) -> CGRect {
            if handle == .move {
                var moved = original.offsetBy(dx: delta.width, dy: delta.height)
                moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
                moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
                return moved.integral
            }
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if [.left, .topLeft, .bottomLeft].contains(handle) { minX += delta.width }
            if [.right, .topRight, .bottomRight].contains(handle) { maxX += delta.width }
            if [.bottom, .bottomLeft, .bottomRight].contains(handle) { minY += delta.height }
            if [.top, .topLeft, .topRight].contains(handle) { maxY += delta.height }
            let rect = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
            return rect.intersection(bounds).integral
        }

        private func handle(at point: CGPoint) -> Handle? {
            guard let selection else { return nil }
            let slop: CGFloat = 8
            let left = abs(point.x - selection.minX) <= slop, right = abs(point.x - selection.maxX) <= slop
            let bottom = abs(point.y - selection.minY) <= slop, top = abs(point.y - selection.maxY) <= slop
            let alongX = point.x >= selection.minX - slop && point.x <= selection.maxX + slop
            let alongY = point.y >= selection.minY - slop && point.y <= selection.maxY + slop
            switch (left, right, top, bottom) {
            case (true, _, true, _): return .topLeft
            case (_, true, true, _): return .topRight
            case (true, _, _, true): return .bottomLeft
            case (_, true, _, true): return .bottomRight
            default: break
            }
            if left && alongY { return .left }
            if right && alongY { return .right }
            if top && alongX { return .top }
            if bottom && alongX { return .bottom }
            return selection.contains(point) ? .move : nil
        }

        private func cursor(for handle: Handle?) -> NSCursor {
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
            case nil: .crosshair
            }
        }

        // Below the selection's bottom-right corner, or inside it when there's no room below.
        private func placeConfirmButton(near selection: CGRect) {
            confirmButton.sizeToFit()
            let size = confirmButton.frame.size
            let below = selection.minY - size.height - 12
            let x = min(max(selection.maxX - size.width, bounds.minX + 12), bounds.maxX - size.width - 12)
            let y = below >= bounds.minY + 12 ? below : selection.minY + 12
            confirmButton.setFrameOrigin(NSPoint(x: x, y: y))
            confirmButton.isHidden = false
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let hint = (confirmsOnRelease
                ? "Drag to select the area to record. Press Esc to cancel."
                : "Drag to move or resize, then press Return or click Done. Press Esc to cancel.") as NSString
            let hintSize = hint.size(withAttributes: attributes)
            let hintY = confirmsOnRelease ? bounds.midY - hintSize.height / 2 : bounds.maxY - hintSize.height - 60
            if !(confirmsOnRelease && selection != nil) {
                hint.draw(at: CGPoint(x: bounds.midX - hintSize.width / 2, y: hintY), withAttributes: attributes)
            }
            guard let selection else { return }

            // Nearly clear, not clear: macOS sends clicks on fully transparent pixels to the window underneath, so
            // dragging inside the area to move it would never reach this view.
            NSColor.black.withAlphaComponent(0.01).setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5)).stroke()
            if drag?.handle != nil || drag == nil {
                for point in [
                    CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.midX, y: selection.minY),
                    CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.minX, y: selection.midY),
                    CGPoint(x: selection.maxX, y: selection.midY), CGPoint(x: selection.minX, y: selection.maxY),
                    CGPoint(x: selection.midX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY),
                ] {
                    let knob = NSBezierPath(ovalIn: NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                    NSColor.white.setFill()
                    knob.fill()
                    NSColor.black.withAlphaComponent(0.4).setStroke()
                    knob.stroke()
                }
            }
            let label = "\(Int(selection.width))×\(Int(selection.height))" as NSString
            let size = label.size(withAttributes: attributes)
            let above = selection.maxY + 8
            label.draw(at: CGPoint(x: selection.minX, y: above + size.height < bounds.maxY ? above : selection.maxY - size.height - 8), withAttributes: attributes)
        }
    }

    private var overlays: [(screen: NSScreen, window: OverlayWindow, view: SelectionView)] = []
    private var keyMonitor: Any?
    private let completion: ((screen: NSScreen, rect: CGRect)?) -> Void

    // `initial` starts with an existing area selected so it can be moved or resized.
    init(initial: (screen: NSScreen, rect: CGRect)? = nil, completion: @escaping ((screen: NSScreen, rect: CGRect)?) -> Void) {
        self.completion = completion
        NSApp.activate()
        NSCursor.crosshair.set()
        // Esc cancels and Return confirms whichever overlay is key, or none if activation hasn't landed yet.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53:
                MainActor.assumeIsolated { self?.finish(nil) }
                return nil
            case 36, 76:
                MainActor.assumeIsolated { self?.confirmSelection() }
                return nil
            default:
                return event
            }
        }
        let mouse = NSEvent.mouseLocation
        let keyScreen = initial?.screen ?? NSScreen.screens.first { $0.frame.contains(mouse) }
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onBegin = { [weak self, weak view] in self?.clearSelections(except: view) }
            view.onConfirm = { [weak self] rect in self?.finish((screen, rect)) }
            view.confirmsOnRelease = initial == nil
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            if screen == keyScreen {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
            } else {
                window.orderFrontRegardless()
            }
            if let initial, initial.screen == screen {
                view.select(initial.rect)
            }
            overlays.append((screen, window, view))
        }
    }

    private func clearSelections(except keep: SelectionView?) {
        for overlay in overlays where overlay.view !== keep {
            overlay.view.clear()
        }
    }

    private func confirmSelection() {
        if let overlay = overlays.first(where: { $0.view.selection != nil }) {
            overlay.view.confirm()
        }
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

// System-wide shortcuts through Carbon's hot keys, which need no permission. They work while the app runs, even
// hidden, which is the point: the window is hidden while recording.
@MainActor
final class GlobalHotKeys {
    struct Shortcut {
        let keyCode: Int
        let label: String
        let action: () -> Void
    }

    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private var registered: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    // Returns the labels of shortcuts that couldn't be registered, usually because another app holds them.
    func register(_ shortcuts: [Shortcut]) -> [String] {
        unregister()
        if handler == nil {
            installHandler()
        }
        var failed: [String] = []
        for (index, shortcut) in shortcuts.enumerated() {
            let id = EventHotKeyID(signature: 0x5353_5448, id: UInt32(index + 1))
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.modifiers, id, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                registered.append(reference)
                actions[id.id] = shortcut.action
            } else {
                failed.append(shortcut.label)
            }
        }
        return failed
    }

    func unregister() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered = []
        actions = [:]
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            let hotKeys = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

// MARK: - Model

enum RecordingState: Equatable {
    case idle
    case picking
    case needsPermission
    case systemPicker
    case selectingArea
    case ready(String)
    case starting
    case recording(since: Date)
}

// What was last recorded, so Record can offer it again. Areas keep their display-relative rect for capture
// and their global rect for the outline.
enum LastTarget {
    case window(id: CGWindowID, pid: pid_t, phrase: String)
    case display(id: CGDirectDisplayID, phrase: String)
    case area(display: CGDirectDisplayID, rect: CGRect, onScreen: CGRect)

    // How the target reads in a sentence, e.g. "Ready to record the entire screen".
    var phrase: String {
        switch self {
        case let .window(_, _, phrase), let .display(_, phrase): phrase
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
    var thumbnail: CGImage?

    init(display: SCDisplay, number: Int, of count: Int) {
        id = "display-\(display.displayID)"
        kind = .display(display)
        title = count == 1 ? "Entire Screen" : "Display \(number)"
        phrase = count == 1 ? "the entire screen" : "Display \(number)"
        subtitle = "\(Int(display.frame.width))×\(Int(display.frame.height))"
        icon = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
    }

    init(window: SCWindow) {
        let app = window.owningApplication
        id = "window-\(window.windowID)"
        kind = .window(window)
        title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? app?.applicationName ?? "Window"
        phrase = "“\(title)”"
        subtitle = app?.applicationName ?? ""
        icon = app.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }
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
    let tools = Tools.locate()
    // The last selection only matters while recording a series, so an empty list forgets it.
    var clips: [Clip] = [] {
        didSet {
            if clips.isEmpty {
                lastTarget = nil
            }
        }
    }
    var outputSize: OutputSize = .p1080
    var quality: Quality = .standard
    var state: EncodeState = .idle
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
            }
        }
    }
    var targets: [CaptureTarget] = []
    var hoveredTarget: String?
    var lastTarget: LastTarget?
    var thumbnails: [UUID: NSImage] = [:]
    var useGlobalShortcuts = UserDefaults.standard.object(forKey: "useGlobalShortcuts") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useGlobalShortcuts, forKey: "useGlobalShortcuts")
            updateGlobalShortcuts()
        }
    }
    var shortcutProblem: String?
    @ObservationIgnored private let hotKeys = GlobalHotKeys()
    var previewClip: UUID?
    @ObservationIgnored var previewPlayer: AVPlayer?
    var recordMicrophone = UserDefaults.standard.bool(forKey: "recordMicrophone") {
        didSet { UserDefaults.standard.set(recordMicrophone, forKey: "recordMicrophone") }
    }
    var recordingsFolder = UserDefaults.standard.string(forKey: "recordingsFolder")
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? StitchModel.defaultRecordingsFolder {
        didSet { UserDefaults.standard.set(recordingsFolder.path, forKey: "recordingsFolder") }
    }

    private var probing: Set<URL> = []
    @ObservationIgnored private var recorder: Recorder?
    @ObservationIgnored private var controls: RecordingControls?
    @ObservationIgnored private var ourApps: [SCRunningApplication] = []
    @ObservationIgnored private var displays: [SCDisplay] = []
    @ObservationIgnored private var areaSelector: AreaSelector?
    @ObservationIgnored private var outline: AreaOutline?
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
    var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } }
    var totalBytes: Int64 { clips.reduce(0) { $0 + $1.fileSize } }

    var summary: String {
        guard !clips.isEmpty else { return "" }
        let (width, height) = EncodeJob.canvas(for: clips, size: outputSize)
        let count = clips.count == 1 ? "1 clip" : "\(clips.count) clips"
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
        panel.message = "Choose the videos to combine"
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
                clips += added.sorted(by: Clip.chronological)
            } else {
                clips += added
                clips.sort(by: Clip.chronological)
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
            warning = "Couldn't create \(abbreviatedPath(recordingsFolder)): \(error.localizedDescription)"
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
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
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
                window.windowLayer == 0 && window.isOnScreen && window.frame.width >= 120 && window.frame.height >= 80
                    && window.owningApplication.map { $0.bundleIdentifier != bundleID } == true
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
        case let .area(id, rect, onScreen):
            if let display = content.displays.first(where: { $0.displayID == id }) {
                outline = AreaOutline(around: onScreen)
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
            getReady(
                target.filter(excluding: ourApps),
                area: nil,
                remembering: .window(id: window.windowID, pid: pid, phrase: target.phrase),
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
        outline = AreaOutline(around: onScreen)
        let filter = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])
        getReady(filter, area: area, remembering: .area(display: id, rect: area, onScreen: onScreen), bringingForward: nil)
    }

    // Shows the floating bar with Start so the user can set things up first, and hands focus to the window
    // they picked.
    private func getReady(_ filter: SCContentFilter, area: CGRect?, remembering target: LastTarget, bringingForward app: NSRunningApplication?) {
        pendingFilter = filter
        pendingArea = area
        pendingTarget = target
        recordingState = .ready(target.phrase)
        controls = RecordingControls(model: self)
        if let app {
            NSApp.yieldActivation(to: app)
        }
        NSApp.hide(nil)
        app?.activate(from: .current, options: [])
    }

    func beginRecording() {
        guard case .ready = recordingState, let filter = pendingFilter else { return }
        lastTarget = pendingTarget
        recordingState = .starting
        makeRecorder().record(filter, area: pendingArea)
    }

    func cancelReady() {
        guard case .ready = recordingState else { return }
        endRecording()
    }

    var isAreaReady: Bool {
        if case .ready = recordingState, case .area = pendingTarget { true } else { false }
    }

    // Reopens the selector on the current area, then returns to Ready with the adjusted one (or the old one on Esc).
    // The main window is ordered out first so activating the app for the selector doesn't bring it back.
    func adjustArea() {
        guard case .ready = recordingState, case let .area(id, _, onScreen)? = pendingTarget,
              let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
        outline?.remove()
        outline = nil
        controls?.setHidden(true)
        mainWindow?.orderOut(nil)
        recordingState = .selectingArea
        let local = onScreen.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        areaSelector = AreaSelector(initial: (screen, local)) { [weak self] result in
            MainActor.assumeIsolated { self?.areaAdjusted(result, previous: onScreen) }
        }
    }

    private func areaAdjusted(_ result: (screen: NSScreen, rect: CGRect)?, previous: CGRect) {
        areaSelector = nil
        if let result, let id = result.screen.displayID,
           let filter = pendingFilterFor(display: id) {
            let screen = result.screen.frame
            let onScreen = result.rect.offsetBy(dx: screen.minX, dy: screen.minY)
            let area = CGRect(x: result.rect.minX, y: screen.height - result.rect.maxY, width: result.rect.width, height: result.rect.height)
            pendingFilter = filter
            pendingArea = area
            pendingTarget = .area(display: id, rect: area, onScreen: onScreen)
            outline = AreaOutline(around: onScreen)
        } else {
            outline = AreaOutline(around: previous)
        }
        recordingState = .ready(pendingTarget?.phrase ?? "")
        controls?.setHidden(false)
        NSApp.hide(nil)
    }

    // The same display keeps the filter it has; another display needs its own.
    private func pendingFilterFor(display id: CGDirectDisplayID) -> SCContentFilter? {
        if case let .area(current, _, _)? = pendingTarget, current == id {
            return pendingFilter
        }
        return displays.first { $0.displayID == id }.map {
            SCContentFilter(display: $0, excludingApplications: ourApps, exceptingWindows: [])
        }
    }

    func changeTarget() {
        guard case .ready = recordingState else { return }
        removeRecordingControls()
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        showPicker()
    }

    func updateGlobalShortcuts() {
        guard useGlobalShortcuts else {
            hotKeys.unregister()
            shortcutProblem = nil
            return
        }
        let failed = hotKeys.register([
            .init(keyCode: kVK_ANSI_R, label: "⌃⌥⌘R") { [weak self] in self?.recordShortcut() },
            .init(keyCode: kVK_ANSI_S, label: "⌃⌥⌘S") { [weak self] in self?.showApp() },
        ])
        shortcutProblem = failed.isEmpty ? nil : "\(failed.joined(separator: " and ")) is already used by another app."
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
    private func handleRecording(_ event: Recorder.Event) {
        switch event {
        case .started:
            recordingState = .recording(since: Date())
            if controls == nil {
                controls = RecordingControls(model: self)
                NSApp.hide(nil)
            }
        case let .finished(url):
            endRecording()
            if let url {
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
        controls?.remove()
        controls = nil
        outline?.remove()
        outline = nil
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

    func moveSourcesToTrash() {
        guard case .done = state, !clips.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = clips.count == 1 ? "Move the original clip to the Trash?" : "Move the \(clips.count) original clips to the Trash?"
        alert.informativeText = "The combined video isn't affected. The space (\(formatBytes(totalBytes))) is freed when you empty the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var failed: [Clip] = []
        for clip in clips {
            do {
                try FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
            } catch {
                failed.append(clip)
            }
        }
        let moved = clips.count - failed.count
        clips = failed
        if failed.isEmpty {
            notice = moved == 1 ? "Moved 1 original clip to the Trash." : "Moved \(moved) original clips to the Trash."
        } else {
            warning = "Couldn't move to the Trash: \(failed.map(\.name).joined(separator: ", "))"
        }
    }

    private func loadThumbnail(for clip: Clip) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let time = CMTime(seconds: min(1, clip.duration / 2), preferredTimescale: 600)
        guard let frame = try? await generator.image(at: time) else { return }
        thumbnails[clip.id] = NSImage(cgImage: frame.image, size: .zero)
    }

    func preview(_ clip: Clip) {
        endPreview()
        previewPlayer = AVPlayer(url: clip.url)
        previewPlayer?.play()
        previewClip = clip.id
    }

    func endPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        previewClip = nil
    }

    func remove(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        thumbnails[clip.id] = nil
        clearResult()
    }

    func move(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
        isManuallyOrdered = true
        clearResult()
    }

    func sortByDate() {
        clips.sort(by: Clip.chronological)
        isManuallyOrdered = false
    }

    func clear() {
        clips = []
        thumbnails = [:]
        isManuallyOrdered = false
        warning = nil
    }

    func confirmClear() {
        guard !clips.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = clips.count == 1 ? "Clear the clip from the list?" : "Clear all \(clips.count) clips from the list?"
        alert.informativeText = "The files aren't deleted."
        alert.addButton(withTitle: "Clear List")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            clear()
        }
    }

    var isDateOrdered: Bool {
        !isManuallyOrdered
    }

    func chooseOutputAndEncode() {
        guard let first = clips.first else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = first.url.deletingLastPathComponent()
        panel.nameFieldStringValue = first.url.deletingPathExtension().lastPathComponent + " combined.mp4"
        panel.message = "Choose where to save the combined video"
        guard panel.runModal() == .OK, let output = panel.url?.standardizedFileURL else { return }
        guard !clips.contains(where: { $0.url == output }) else {
            state = .failed("That file is one of the clips being combined. Choose a different name or folder.")
            return
        }
        encode(to: output)
    }

    func encode(to output: URL) {
        guard let tools, !clips.isEmpty, !isEncoding else { return }
        let job = EncodeJob(clips: clips, size: outputSize, quality: quality, output: output)
        let run = FFmpegRun()
        do {
            try run.start(
                ffmpeg: tools.ffmpeg,
                arguments: job.arguments,
                duration: job.duration,
                onProgress: { value in Task { @MainActor in self.progress = value } },
                onExit: { status, errors in Task { @MainActor in self.finish(status: status, errors: errors) } }
            )
        } catch {
            state = .failed("Couldn't start ffmpeg: \(error.localizedDescription)")
            return
        }
        self.run = run
        self.job = job
        // Standardizing only strips /private from paths that exist, so do it on the folder.
        seenFiles.insert(output.deletingLastPathComponent().standardizedFileURL.appendingPathComponent(output.lastPathComponent))
        cancelled = false
        progress = 0
        startedAt = Date()
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
        try? FileManager.default.removeItem(at: job.output)
    }

    private func finish(status: Int32, errors: String) {
        guard let job else { return }
        self.run = nil
        self.job = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }

        if cancelled {
            try? FileManager.default.removeItem(at: job.output)
            state = .idle
        } else if status == 0 {
            let bytes = (try? job.output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            progress = 1
            state = .done(output: job.output, outputBytes: Int64(bytes), inputBytes: clips.reduce(0) { $0 + $1.fileSize })
            NSApp.requestUserAttention(.informationalRequest)
        } else {
            try? FileManager.default.removeItem(at: job.output)
            state = .failed(errors.isEmpty
                ? "Couldn't combine the clips (ffmpeg exited with status \(status))."
                : "Couldn't combine the clips. ffmpeg reported:\n\(errors)")
        }
    }

    private func clearResult() {
        if !isEncoding {
            state = .idle
        }
    }
}

// MARK: - Views

// Command Line Tools lack the SwiftUIMacros plugin, so view state lives on the model instead of @State.
struct ContentView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.tools == nil {
                ContentUnavailableView {
                    Label("FFmpeg isn't installed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Screen Stitch uses FFmpeg to combine and compress clips. Install it with Homebrew (`brew install ffmpeg`), then reopen the app.")
                } actions: {
                    Button("Quit & Reopen") { model.relaunch() }
                }
            } else if model.clips.isEmpty {
                EmptyStateView()
            } else {
                ClipList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.hasBottomBar {
                VStack(spacing: 0) {
                    Divider()
                    BottomBar()
                }
                .background(.background)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .overlay {
            if model.isProbing {
                ProgressView("Reading clips…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        // The permission card isn't a sheet: macOS won't quit an app with a sheet open, which breaks the
        // Quit & Reopen that granting Screen Recording asks for.
        .overlay {
            if model.recordingState == .systemPicker || model.recordingState == .needsPermission {
                ZStack {
                    Color.black.opacity(0.15)
                    if model.recordingState == .systemPicker {
                        ChoosingCard()
                    } else {
                        PermissionNeeded()
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.recordingState == .picking },
            set: { presented in
                if !presented, model.recordingState == .picking {
                    model.cancelRecording()
                }
            }
        )) {
            TargetPicker()
                .environment(model)
        }
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isEncoding else { return false }
            model.add(urls)
            return true
        } isTargeted: { targeted in
            model.isDropTargeted = targeted && !model.isEncoding
        }
        // The start screen has its own buttons for all of this, so the toolbar waits until there's a clip.
        .toolbar {
            let locked = model.isEncoding || model.tools == nil
            if !model.clips.isEmpty {
                ToolbarItemGroup {
                    Toggle(isOn: Binding(get: { model.recordMicrophone }, set: { model.recordMicrophone = $0 })) {
                        Label("Record Microphone", systemImage: model.recordMicrophone ? "mic.fill" : "mic.slash")
                    }
                    .help(model.recordMicrophone ? "Turn off the microphone for new recordings" : "Turn on the microphone for new recordings")
                    .disabled(model.isRecording)
                    Toggle(isOn: Binding(get: { model.isWatching }, set: { $0 ? model.startWatching() : model.stopWatching() })) {
                        Label("Watch for Recordings", systemImage: "eye")
                    }
                    .help(model.isWatching
                        ? "Stop watching \(model.watchFolder?.lastPathComponent ?? "")"
                        : "Watch \(StitchModel.screenshotFolder().lastPathComponent) for new screen recordings")
                    Button("Add Videos…", systemImage: "plus") { model.chooseFiles() }
                        .help("Add video files to the list")
                        .disabled(locked)
                }
            }
        }
    }
}

// Recording is the main use, so it gets the one big button. The alternatives are plain buttons whose details live in
// their tooltips, and where recordings go is a quiet footer.
struct EmptyStateView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        let watched = (model.watchFolder ?? StitchModel.screenshotFolder()).lastPathComponent
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                Text("Record clips, then stitch them into one video")
                    .font(.title2.weight(.semibold))
                Text("Screen Stitch combines your clips into a single compressed MP4.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.bottom, 32)

            Button { model.startRecording() } label: {
                Label("Record Screen", systemImage: "record.circle")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 260)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.extraLarge)
            .padding(.bottom, 12)

            Text("Pick a window, display or area to record.")
                .foregroundStyle(.secondary)
            if model.useGlobalShortcuts {
                Text("⌃⌥⌘R starts and stops recording from any app.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }

            HStack(spacing: 12) {
                VStack { Divider() }
                Text("or")
                    .foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .frame(width: 320)
            .padding(.top, 40)
            .padding(.bottom, 16)

            HStack(spacing: 12) {
                Button { model.isWatching ? model.stopWatching() : model.startWatching() } label: {
                    Label(model.isWatching ? "Stop Watching" : "Watch for Recordings", systemImage: "eye")
                }
                .help(model.isWatching
                    ? "Stop adding new recordings from \(watched)"
                    : "Add recordings from the macOS Screenshot toolbar as soon as they're saved to \(watched)")
                Button { model.chooseFiles() } label: {
                    Label("Add Videos…", systemImage: "plus")
                }
                .help("Add existing video files")
            }
            .controlSize(.large)
            Text("You can also drop video files anywhere in this window.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)

            Spacer()
            RecordingsFolderLine()
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingsFolderLine: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Recordings save to \(abbreviatedPath(model.recordingsFolder))")
                .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Button("Change…") { model.chooseRecordingsFolder() }
                .buttonStyle(.link)
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Button("Show in Finder") { model.showRecordingsFolder() }
                .buttonStyle(.link)
        }
        .font(.caption)
    }
}

struct ChoosingCard: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Choose in the macOS picker", systemImage: "record.circle")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                step(1, "In the macOS picker, click the window, app or display you want to record.")
                step(2, "Recording starts right away, and this window hides.")
                step(3, "When you're done, click Stop in the floating bar at the top of the screen. Stop is also in the menu bar. The recording is added to the list.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Record Microphone", isOn: Binding(get: { model.recordMicrophone }, set: { model.recordMicrophone = $0 }))
                    .font(.caption)
                RecordingsFolderLine()
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelRecording() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 470)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.callout.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TargetPicker: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose what to record")
                        .font(.title2.weight(.semibold))
                    Text("Pick a window, display or area. Recording starts when you click Start in the floating bar.")
                        .foregroundStyle(.secondary)
                    if let warning = model.warning {
                        Label {
                            Text(verbatim: warning)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer()
                Toggle("Record Microphone", isOn: Binding(get: { model.recordMicrophone }, set: { model.recordMicrophone = $0 }))
                    .help("You can also change it in the floating bar before you click Start")
            }
            .padding(20)
            Divider()
            Group {
                if model.targets.isEmpty {
                    ProgressView("Finding windows and displays…")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            section("Displays", model.targets.filter(\.isDisplay), includingArea: true)
                            section("Windows", model.targets.filter { !$0.isDisplay }, includingArea: false)
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                RecordingsFolderLine()
                Spacer()
                if model.recordingState == .picking {
                    Button("Use macOS Picker…") { model.useSystemPicker() }
                        .help("Use Apple's picker instead. It can't record an area.")
                }
                Button("Cancel") { model.cancelRecording() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 700, idealWidth: 880, minHeight: 480, idealHeight: 640)
    }

    @ViewBuilder
    private func section(_ title: String, _ targets: [CaptureTarget], includingArea: Bool) -> some View {
        if !targets.isEmpty || includingArea {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: title)
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], alignment: .leading, spacing: 18) {
                    if includingArea {
                        AreaTile()
                    }
                    ForEach(targets) { TargetTile(target: $0) }
                }
            }
        }
    }
}

struct TargetTile: View {
    @Environment(StitchModel.self) private var model
    let target: CaptureTarget

    var body: some View {
        let hovered = model.hoveredTarget == target.id
        Button {
            model.record(target)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                    if let thumbnail = target.thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovered ? Color.accentColor : .clear, lineWidth: 3))
                HStack(spacing: 6) {
                    if let icon = target.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: target.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: target.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                model.hoveredTarget = target.id
            } else if model.hoveredTarget == target.id {
                model.hoveredTarget = nil
            }
        }
        .help("Choose \(target.phrase)")
    }
}

struct AreaTile: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        let hovered = model.hoveredTarget == "area"
        Button {
            model.selectArea()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .foregroundStyle(.secondary)
                        .padding(28)
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovered ? Color.accentColor : .clear, lineWidth: 3))
                HStack(spacing: 6) {
                    Image(systemName: "crop")
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Select Area")
                        Text("Drag to select part of the screen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                model.hoveredTarget = "area"
            } else if model.hoveredTarget == "area" {
                model.hoveredTarget = nil
            }
        }
        .help("Record just part of the screen")
    }
}

struct PermissionNeeded: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Screen Stitch needs Screen Recording access")
                .font(.title3.weight(.semibold))
            Text("Turn on Screen Stitch in System Settings › Privacy & Security › Screen & System Audio Recording, then click Quit & Reopen (here or in the macOS prompt). macOS only applies the change after a relaunch.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") { model.openScreenRecordingSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Quit & Reopen") { model.relaunch() }
            }
            HStack(spacing: 16) {
                Button("Use macOS Picker…") { model.useSystemPicker() }
                    .buttonStyle(.link)
                Button("Cancel") { model.cancelRecording() }
                    .buttonStyle(.link)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.callout)
        }
        .padding(28)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
    }
}

struct SettingsView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("Save recordings to") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: abbreviatedPath(model.recordingsFolder))
                    HStack {
                        Button("Change…") { model.chooseRecordingsFolder() }
                        Button("Show in Finder") { model.showRecordingsFolder() }
                        if model.recordingsFolder != StitchModel.defaultRecordingsFolder {
                            Button("Use Default") { model.recordingsFolder = StitchModel.defaultRecordingsFolder }
                        }
                    }
                }
            }
            Toggle("Record microphone", isOn: Binding(get: { model.recordMicrophone }, set: { model.recordMicrophone = $0 }))
            LabeledContent("Shortcuts") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Use from any app", isOn: Binding(get: { model.useGlobalShortcuts }, set: { model.useGlobalShortcuts = $0 }))
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text(verbatim: "⌃⌥⌘R").monospaced()
                            Text("Record, then Start, then Stop")
                        }
                        GridRow {
                            Text(verbatim: "⌃⌥⌘S").monospaced()
                            Text("Show Screen Stitch")
                        }
                    }
                    .foregroundStyle(model.useGlobalShortcuts ? .primary : .secondary)
                    if let problem = model.shortcutProblem {
                        Text(verbatim: problem)
                            .foregroundStyle(.red)
                    }
                    Text("They work while Screen Stitch is open, even in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct ClipList: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ClipListHeader()
            Divider()
            List {
                ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                    ClipRow(index: index, clip: clip)
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .disabled(model.isEncoding)
            Divider()
            RecordAnotherBar()
        }
    }
}

struct ClipListHeader: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            Text(verbatim: model.clips.count == 1 ? "1 clip" : "\(model.clips.count) clips")
                .font(.headline)
            Text(model.isDateOrdered ? "In recording order. Drag to reorder." : "Custom order. New clips go at the end.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Sort by Date") { model.sortByDate() }
                .disabled(model.isDateOrdered || model.clips.count < 2)
                .help("Put the clips back in the order they were recorded")
            Button("Clear List…") { model.confirmClear() }
                .help("Remove every clip from the list. The files aren't deleted.")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .disabled(model.isEncoding || model.isRecording)
    }
}

struct RecordAnotherBar: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Button { model.startRecording() } label: {
                Label(model.lastTarget == nil ? "Record Screen" : "Record Another", systemImage: "record.circle")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            VStack(alignment: .leading, spacing: 2) {
                if let last = model.lastTarget {
                    Text(verbatim: "Same as last time: \(last.phrase)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Pick a window, display or area to record. The recording is added to this list when you stop.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if model.lastTarget != nil {
                Button("Record Something Else…") { model.pickTarget() }
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .disabled(model.isEncoding || model.isRecording)
    }
}

// AVKit's SwiftUI VideoPlayer crashes on launch with the Command Line Tools SDK, so wrap the AppKit view.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}

struct ClipRow: View {
    @Environment(StitchModel.self) private var model
    let index: Int
    let clip: Clip

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            Button {
                model.preview(clip)
            } label: {
                ZStack {
                    Color.black
                    if let thumbnail = model.thumbnails[clip.id] {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.black.opacity(0.5), in: Circle())
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Preview")
            .popover(isPresented: Binding(
                get: { model.previewClip == clip.id },
                set: { if !$0, model.previewClip == clip.id { model.endPreview() } }
            ), arrowEdge: .trailing) {
                if let player = model.previewPlayer {
                    let height = 640 * CGFloat(clip.height) / CGFloat(max(clip.width, 1))
                    PlayerView(player: player)
                        .frame(width: 640, height: min(max(height, 240), 520))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: clip.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(abbreviatedPath(clip.url))
                Text(clip.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if clip.audioStreams > 0 {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                    .help("Has audio")
            }
            Text(verbatim: "\(clip.width)×\(clip.height)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: formatDuration(clip.duration))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
            Text(verbatim: formatBytes(clip.fileSize))
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            Button {
                model.remove(clip)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Remove from List")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Preview") { model.preview(clip) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            Button("Remove from List") { model.remove(clip) }
        }
    }
}

struct BottomBar: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        @Bindable var settings = model
        VStack(alignment: .leading, spacing: 12) {
            switch model.recordingState {
            case let .recording(since):
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(verbatim: "Recording \(formatDuration(context.date.timeIntervalSince(since)))")
                            .monospacedDigit()
                    }
                    Button("Stop") { model.stopRecording() }
                }
            default:
                EmptyView()
            }
            StatusView()
            if let folder = model.watchFolder {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                    Text(verbatim: "Watching \(folder.lastPathComponent) for new screen recordings")
                    Button("Change…") { model.chooseWatchFolder() }
                        .buttonStyle(.link)
                    Button("Stop Watching") { model.stopWatching() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let warning = model.warning {
                Label {
                    Text(verbatim: warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
            }
            if let notice = model.notice {
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let summary = Text(verbatim: model.summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            let controls = HStack(spacing: 16) {
                Picker("Resolution", selection: $settings.outputSize) {
                    ForEach(OutputSize.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                .help("Caps the shorter side of the output. Smaller clips are scaled up to match the largest.")
                Picker("Quality", selection: $settings.quality) {
                    ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .help("Higher quality makes a larger file")
                Button("Combine & Compress…") { model.chooseOutputAndEncode() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.clips.isEmpty || model.isProbing)
            }
            .fixedSize()
            if !model.clips.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        summary.fixedSize()
                        Spacer()
                        controls
                    }
                    VStack(alignment: .trailing, spacing: 10) {
                        summary.frame(maxWidth: .infinity, alignment: .leading)
                        controls
                    }
                }
                .disabled(model.isEncoding || model.isRecording || model.tools == nil)
            }
        }
        .padding()
    }
}

struct StatusView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .encoding:
            HStack(spacing: 12) {
                ProgressView(value: model.progress)
                Text(verbatim: model.progressText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancel() }
            }
        case let .done(output, outputBytes, inputBytes):
            let saved = Label {
                Text(verbatim: "Saved \(output.lastPathComponent) · \(formatBytes(outputBytes))\(savings(outputBytes, inputBytes))")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            let actions = HStack(spacing: 8) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                Button("Open") { NSWorkspace.shared.open(output) }
                if !model.clips.isEmpty {
                    Button("Move Originals to Trash…") { model.moveSourcesToTrash() }
                        .help("Move the original clips to the Trash")
                }
            }
            .fixedSize()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    saved.fixedSize()
                    Spacer()
                    actions
                }
                VStack(alignment: .leading, spacing: 8) {
                    saved
                    actions
                }
            }
        case let .failed(message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(verbatim: message)
                    .font(.callout)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
        }
    }

    private func savings(_ outputBytes: Int64, _ inputBytes: Int64) -> String {
        guard inputBytes > 0 else { return "" }
        let ratio = Double(outputBytes) / Double(inputBytes)
        let percent = Int((abs(1 - ratio) * 100).rounded())
        return ratio <= 1 ? " (\(percent)% smaller)" : " (\(percent)% larger)"
    }
}

// MARK: - Formatting

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

func abbreviatedPath(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}

// MARK: - Command line

enum CLI {
    private final class ExitBox: @unchecked Sendable {
        var status: Int32 = 1
        var errors = ""
    }

    static func run(_ arguments: [String]) -> Never {
        var size = OutputSize.p1080
        var quality = Quality.standard
        var paths: [String] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--size":
                guard let value = iterator.next(), let parsed = OutputSize(argument: value) else { usage() }
                size = parsed
            case "--quality":
                guard let value = iterator.next(), let parsed = Quality(argument: value) else { usage() }
                quality = parsed
            default:
                paths.append(argument)
            }
        }
        guard paths.count >= 2 else { usage() }
        guard let tools = Tools.locate() else { fail("ffmpeg not found; install it with `brew install ffmpeg`") }

        let output = URL(fileURLWithPath: paths.removeFirst()).standardizedFileURL
        var clips: [Clip] = []
        for path in paths {
            do {
                clips.append(try Prober.probe(URL(fileURLWithPath: path).standardizedFileURL, ffprobe: tools.ffprobe))
            } catch {
                log("Skipping \(path): \(error.localizedDescription)")
            }
        }
        guard !clips.isEmpty else { fail("no readable videos") }
        clips.sort(by: Clip.chronological)

        for (index, clip) in clips.enumerated() {
            log("\(index + 1). \(clip.name)  \(clip.date.formatted(date: .abbreviated, time: .standard))  \(formatDuration(clip.duration))  \(clip.width)×\(clip.height)  audio streams: \(clip.audioStreams)")
        }
        let job = EncodeJob(clips: clips, size: size, quality: quality, output: output)
        log("ffmpeg " + job.arguments.map { $0.contains(" ") || $0.contains(";") ? "'\($0)'" : $0 }.joined(separator: " "))

        let finished = DispatchSemaphore(value: 0)
        let result = ExitBox()
        do {
            try FFmpegRun().start(
                ffmpeg: tools.ffmpeg,
                arguments: job.arguments,
                duration: job.duration,
                onProgress: { value in FileHandle.standardError.write(Data("\r\(Int(value * 100))%".utf8)) },
                onExit: { status, errors in
                    result.status = status
                    result.errors = errors
                    finished.signal()
                }
            )
        } catch {
            fail("couldn't start ffmpeg: \(error.localizedDescription)")
        }
        finished.wait()
        log("")
        guard result.status == 0 else { fail("ffmpeg failed (\(result.status)):\n\(result.errors)") }
        let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        log("Wrote \(output.path) (\(formatBytes(Int64(bytes))); inputs \(formatBytes(clips.reduce(0) { $0 + $1.fileSize })))")
        exit(0)
    }

    private static func usage() -> Never {
        fail("usage: ScreenStitch --cli [--size original|1440|1080|720 (default 1080)] [--quality high|standard|small (default standard)] OUTPUT.mp4 INPUT...")
    }

    private static func fail(_ message: String) -> Never {
        log(message)
        exit(1)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
