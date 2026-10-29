import AppKit
import Carbon.HIToolbox
import AVFoundation
import os
import Quartz
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
        Button("Clear Session") { model.clearSession() }
            .keyboardShortcut("n")
            .disabled(busy || (model.clips.isEmpty && model.state == .idle))
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
    private var spaceMonitor: Any?

    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls)
    }

    // Quit when the main window closes. AppKit's "terminate after last window closed" (SwiftUI turns it on for
    // single-Window apps) also fires when the recording controls go away while the window is hidden, which quit
    // the app on Stop.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            guard (notification.object as? NSWindow)?.identifier?.rawValue == "main" else { return }
            RunLoop.main.perform { NSApp.terminate(nil) }
        }

        // Space opens Quick Look from anywhere in the main window, not only when the list has focus, unless text is
        // being typed.
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [model] event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard Int(event.keyCode) == kVK_Space, modifiers.isEmpty, let window = event.window,
                  window.identifier?.rawValue == "main", !(window.firstResponder is NSText) else { return event }
            return MainActor.assumeIsolated { model.toggleQuickLook() } ? nil : event
        }

        // `build.sh --install` sends SIGTERM; quit the normal way so an export in progress is cleaned up.
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Quitting can wait for a recording to finish, which needs the main queue, so it can't run inside one of its blocks.
        terminationSignal?.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
        terminationSignal?.resume()

        model.updateGlobalShortcuts()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.updateGlobalShortcuts()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.finishRecordingBeforeQuit { NSApp.reply(toApplicationShouldTerminate: true) } ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.abortForQuit()
    }

    // Quick Look asks the responder chain for a controller, and the chain ends at the app delegate.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension AppDelegate: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        model.quickLookItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let items = model.quickLookItems
        return items.indices.contains(index) ? items[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch Int(event.keyCode) {
        case kVK_UpArrow: model.moveSelection(by: -1)
        case kVK_DownArrow: model.moveSelection(by: 1)
        default: return false
        }
        return true
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
    // Codec, size and encoder settings of every track. Clips with the same one can be joined without re-encoding; nil
    // when a track can't go in an MP4 as is.
    var copyFormat: String? = nil

    var name: String { url.lastPathComponent }

    static func chronological(_ a: Clip, _ b: Clip) -> Bool {
        a.date != b.date ? a.date < b.date : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

// Text shown full-frame between clips in the combined video, such as "Before…" and "After…".
struct TitleCard: Identifiable, Hashable {
    static let durations: ClosedRange<Double> = 0.25...10

    enum Role {
        case before
        case after
    }

    let id = UUID()
    var text: String
    var duration: Double = 1.25
    // Black text on white instead of white on black.
    var isLight = false
    // Set on the cards Before & After adds, so turning it off removes just those.
    var role: Role?
}

// A row in the session: a clip, or a title card that goes between clips.
enum SessionItem: Identifiable, Hashable {
    case clip(Clip)
    case card(TitleCard)

    var id: UUID {
        switch self {
        case let .clip(clip): clip.id
        case let .card(card): card.id
        }
    }

    var clip: Clip? {
        if case let .clip(clip) = self { clip } else { nil }
    }

    var card: TitleCard? {
        if case let .card(card) = self { card } else { nil }
    }
}

// Draws a title card at the video's size: centered text in New York, Apple's serif, white on black or black on white.
enum TitleCardImage {
    static func png(_ card: TitleCard, width: Int, height: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let canvas = NSRect(x: 0, y: 0, width: width, height: height)
        (card.isLight ? NSColor.white : NSColor.black).setFill()
        canvas.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let size = CGFloat(min(width, height)) * 0.09
        let system = NSFont.systemFont(ofSize: size, weight: .medium)
        let font = system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: card.isLight ? NSColor.black : NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let text = card.text as NSString
        let box = canvas.insetBy(dx: canvas.width * 0.1, dy: canvas.height * 0.1)
        let measured = text.boundingRect(with: box.size, options: [.usesLineFragmentOrigin], attributes: attributes)
        let rect = NSRect(x: box.minX, y: (canvas.height - measured.height) / 2, width: box.width, height: measured.height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
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
            let codec_name: String?
            let profile: String?
            let pix_fmt: String?
            let width: Int?
            let height: Int?
            let sample_rate: String?
            let channels: Int?
            let extradata_hash: String?
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
        process.arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_data_hash", "SHA256", url.path]
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
            fileSize: Int64(fileSize),
            copyFormat: copyFormat(info.streams, rotation: rotation)
        )
    }

    // Joining files as they are needs every track to match exactly, down to the encoder settings in the extradata.
    private static func copyFormat(_ streams: [Output.Stream], rotation: Int) -> String? {
        let tracks = streams.filter { $0.disposition?["attached_pic"] != 1 && ($0.codec_type == "video" || $0.codec_type == "audio") }
        let copyable = tracks.allSatisfy { track in
            track.codec_type == "video" ? ["h264", "hevc"].contains(track.codec_name ?? "") : track.codec_name == "aac"
        }
        guard copyable, tracks.contains(where: { $0.codec_type == "video" }) else { return nil }
        let parts = tracks.map { track in
            [track.codec_type, track.codec_name, track.profile, track.pix_fmt, track.width.map(String.init), track.height.map(String.init),
             track.sample_rate, track.channels.map(String.init), track.extradata_hash].map { $0 ?? "-" }.joined(separator: ":")
        }
        return (parts + ["rotation:\(rotation)"]).joined(separator: "|")
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
    enum Mode {
        case compress
        // Joins the clips as they are, without re-encoding. Only for clips with the same copyFormat; `list` is where the
        // concat list gets written.
        case join(list: URL)
    }

    enum Segment {
        case clip(Clip)
        // A title card, already drawn at the video's size.
        case card(TitleCard, image: URL)
    }

    let segments: [Segment]
    let size: OutputSize
    let quality: Quality
    let output: URL
    var mode = Mode.compress
    // The concat list and title card images, deleted when the run ends.
    var temporaryFiles: [URL] = []

    init(segments: [Segment], size: OutputSize, quality: Quality, output: URL) {
        self.segments = segments
        self.size = size
        self.quality = quality
        self.output = output
    }

    init(clips: [Clip], size: OutputSize, quality: Quality, output: URL) {
        self.init(segments: clips.map { .clip($0) }, size: size, quality: quality, output: output)
    }

    var clips: [Clip] {
        segments.compactMap { if case let .clip(clip) = $0 { clip } else { nil } }
    }

    static func canJoin(_ clips: [Clip]) -> Bool {
        guard clips.count > 1, let format = clips[0].copyFormat else { return false }
        return clips.allSatisfy { $0.copyFormat == format }
    }

    // FFmpeg's concat list: one quoted path per line, with quotes inside a path escaped as '\''.
    var concatList: String {
        clips.map { "file '" + $0.url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: "\n") + "\n"
    }

    var duration: Double {
        segments.reduce(0) { total, segment in
            switch segment {
            case let .clip(clip): total + clip.duration
            case let .card(card, _): total + card.duration
            }
        }
    }

    // The frame is as wide as the widest clip and as tall as the tallest; the size cap applies to its short side so
    // portrait video works too. Every clip is scaled by the same factor, so smaller ones aren't enlarged.
    static func canvas(for clips: [Clip], size: OutputSize) -> (width: Int, height: Int, scale: Double) {
        guard !clips.isEmpty else { return (0, 0, 1) }
        let width = Double(clips.map(\.width).max() ?? 0)
        let height = Double(clips.map(\.height).max() ?? 0)
        var scale = 1.0
        if size != .original, min(width, height) > Double(size.rawValue) {
            scale = Double(size.rawValue) / min(width, height)
        }
        return (even(width * scale), even(height * scale), scale)
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }

    var arguments: [String] {
        if case let .join(list) = mode {
            let hevc = clips.first?.copyFormat?.hasPrefix("video:hevc") == true
            return ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list.path,
                    "-map", "0:v", "-map", "0:a?", "-c", "copy"]
                + (hevc ? ["-tag:v", "hvc1"] : [])
                + ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
        }
        let (width, height, scale) = Self.canvas(for: clips, size: size)
        let hasAudio = clips.contains { $0.audioStreams > 0 }
        let audioFormat = "asetpts=PTS-STARTPTS,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"

        // One input per segment, in order; silence for segments without sound comes after them.
        var inputs: [String] = []
        for segment in segments {
            switch segment {
            case let .clip(clip):
                inputs += ["-i", clip.url.path]
            case let .card(card, image):
                inputs += ["-loop", "1", "-framerate", "30", "-t", String(format: "%.3f", card.duration), "-i", image.path]
            }
        }
        var filters: [String] = []
        var outputs = ""
        var nextInput = segments.count

        for (index, segment) in segments.enumerated() {
            let silence = { (seconds: Double) in
                inputs += ["-f", "lavfi", "-t", String(format: "%.3f", seconds), "-i", "anullsrc=r=48000:cl=stereo"]
                filters.append("[\(nextInput):a]\(audioFormat)[a\(index)]")
                nextInput += 1
            }
            switch segment {
            case let .clip(clip):
                filters.append(
                    "[\(index):v:\(clip.videoStream)]setpts=PTS-STARTPTS,"
                        + "scale=w='min(\(width),iw*\(scale))':h='min(\(height),ih*\(scale))'"
                        + ":force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,"
                        + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[v\(index)]"
                )
                outputs += "[v\(index)]"
                guard hasAudio else { continue }
                switch clip.audioStreams {
                case 0:
                    silence(clip.duration)
                case 1:
                    filters.append("[\(index):a:0]\(audioFormat)[a\(index)]")
                default:
                    let streams = (0..<clip.audioStreams).map { "[\(index):a:\($0)]" }.joined()
                    filters.append("\(streams)amix=inputs=\(clip.audioStreams):duration=longest:normalize=0,\(audioFormat)[a\(index)]")
                }
                outputs += "[a\(index)]"
            case let .card(card, _):
                filters.append("[\(index):v]setpts=PTS-STARTPTS,scale=\(width):\(height),setsar=1,format=yuv420p[v\(index)]")
                outputs += "[v\(index)]"
                guard hasAudio else { continue }
                silence(card.duration)
                outputs += "[a\(index)]"
            }
        }
        filters.append("\(outputs)concat=n=\(segments.count):v=1:a=\(hasAudio ? 1 : 0)[v]\(hasAudio ? "[a]" : "")")

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

        // onExit waits for both pipes, so the last progress line comes before it.
        let outputRead = DispatchGroup()
        outputRead.enter()
        outputRead.enter()
        let lines = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                outputRead.leave()
                return
            }
            for line in lines.append(data) where line.hasPrefix("out_time_us=") {
                if let micros = Double(line.dropFirst("out_time_us=".count)), duration > 0 {
                    onProgress(min(max(micros / 1_000_000 / duration, 0), 1))
                }
            }
        }

        let errors = DataBox()
        process.terminationHandler = { process in
            outputRead.wait()
            let tail = String(decoding: errors.data, as: UTF8.self)
                .split(separator: "\n")
                .suffix(12)
                .joined(separator: "\n")
            onExit(process.terminationStatus, tail)
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        DispatchQueue.global().async {
            errors.data = stderr.fileHandleForReading.readDataToEndOfFile()
            outputRead.leave()
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

final class Recorder: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
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
    private var clip: ClipWriter?
    private var ended = false
    private var configuration: SCStreamConfiguration?
    private var pixelsPerPoint: CGFloat = 1
    private var pendingWindowSize: CGSize?
    private var fitting = false

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

    // The time is taken at the click, so the clip lasts until then even if the screen was still at the end.
    func stop() {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        lock.withLock { stream }?.stopCapture { [self] _ in finish(at: time) }
    }

    // The macOS picker was cancelled, possibly after recording had started: stop and keep nothing.
    func cancel() {
        end(.cancelled)
        discard()
    }

    private func discard() {
        let (stream, clip) = lock.withLock {
            defer { self.clip = nil }
            return (self.stream, self.clip)
        }
        stream?.stopCapture { _ in }
        frames.async { clip?.discard() }
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
        guard !lock.withLock({ ended }) else { return }
        // H.264 tops out at 4096 pixels; screencapture downscales large displays the same way.
        let fit = min(1, 4096 / max(size.width, size.height))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width * fit / 2) * 2
        configuration.height = Int(size.height * fit / 2) * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureMicrophone = microphone
        if let area {
            configuration.sourceRect = area
        }

        let url = folder.appendingPathComponent("Screen Stitch \(Self.fileDate.string(from: Date())).mov")
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let clip: ClipWriter
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
            if microphone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: frames)
            }
            clip = try ClipWriter(url: url, width: configuration.width, height: configuration.height, microphone: microphone)
        } catch {
            end(.failed(error.localizedDescription))
            return
        }
        lock.withLock {
            self.stream = stream
            self.clip = clip
            self.configuration = configuration
            pixelsPerPoint = CGFloat(filter.pointPixelScale) * fit
        }
        stream.startCapture { [self] error in
            if let error {
                end(.failed(error.localizedDescription))
            } else if lock.withLock({ ended }) {
                discard()
            } else {
                onEvent(.started)
            }
        }
    }

    // A window resized mid-recording keeps its scale and is centered in the frame, instead of being stretched or pinned
    // to a corner. Updates are coalesced so a live resize doesn't queue one per tick.
    func fit(windowSize: CGSize) {
        let idle = lock.withLock {
            pendingWindowSize = windowSize
            defer { fitting = true }
            return !fitting
        }
        if idle { applyFit() }
    }

    private func applyFit() {
        let next: (SCStream, SCStreamConfiguration, CGSize, CGFloat)? = lock.withLock {
            guard let stream, let configuration, let size = pendingWindowSize else {
                fitting = false
                return nil
            }
            pendingWindowSize = nil
            return (stream, configuration, size, pixelsPerPoint)
        }
        guard case let (stream, configuration, size, scale)? = next else { return }
        let width = CGFloat(configuration.width)
        let height = CGFloat(configuration.height)
        let fit = min(1, width / (size.width * scale), height / (size.height * scale))
        let content = CGSize(width: (size.width * scale * fit).rounded(), height: (size.height * scale * fit).rounded())
        configuration.destinationRect = CGRect(
            x: ((width - content.width) / 2).rounded(), y: ((height - content.height) / 2).rounded(),
            width: content.width, height: content.height
        )
        stream.updateConfiguration(configuration) { [self] _ in applyFit() }
    }

    // Stopped from the system's screen-sharing menu, or the recorded window closed.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let clip = lock.withLock({ clip }) else { return }
        if let error = clip.append(sampleBuffer, of: type) {
            end(.failed(error.localizedDescription))
        }
    }

    // Queued behind any samples still being delivered. Both Stop and the stream stopping on its own can call this, so
    // the first call takes the writer and later samples and calls find none.
    private func finish(at time: CMTime) {
        frames.async { [self] in
            let clip = lock.withLock {
                defer { self.clip = nil }
                return self.clip
            }
            clip?.finish(at: time) { [self] result in
                switch result {
                case let .success(url): end(.finished(url))
                case let .failure(error): end(.failed(error.localizedDescription))
                }
            }
        }
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

// Writes a recording's frames and microphone audio to a .mov. ScreenCaptureKit's own SCRecordingOutput ends its file
// whenever the stream's configuration changes, which recentering a resized window needs. Used only on the frames queue.
final class ClipWriter {
    private let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private var lastFrame: CMSampleBuffer?

    init(url: URL, width: Int, height: Int, microphone: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if microphone {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            self.audio = audio
        } else {
            audio = nil
        }
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    // Returns the writer's error once it fails. ScreenCaptureKit sends frames without an image while nothing changes;
    // those are skipped, so a still screen costs almost nothing. Sound from before the first frame is dropped.
    func append(_ buffer: CMSampleBuffer, of type: SCStreamOutputType) -> Error? {
        guard writer.status == .writing else { return writer.error }
        switch type {
        case .screen:
            guard buffer.imageBuffer != nil, Self.status(of: buffer) == .complete else { return nil }
            if lastFrame == nil {
                writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            }
            lastFrame = buffer
            if video.isReadyForMoreMediaData {
                video.append(buffer)
            }
        case .microphone:
            if lastFrame != nil, let audio, audio.isReadyForMoreMediaData {
                audio.append(buffer)
            }
        default:
            break
        }
        return writer.status == .failed ? writer.error : nil
    }

    // Repeats the last frame at `time` and ends the clip there, so it lasts until Stop even if the screen was still at
    // the end. A clip with no frames is deleted and reports nil.
    func finish(at time: CMTime, completion: @escaping (Result<URL?, Error>) -> Void) {
        guard writer.status == .writing, let lastFrame else {
            let error = writer.error
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: url)
            completion(error.map { .failure($0) } ?? .success(nil))
            return
        }
        if time > lastFrame.presentationTimeStamp {
            // Without this frame the clip ends at the last change, so wait up to a second if the encoder is busy.
            var waits = 0
            while !video.isReadyForMoreMediaData, waits < 100 {
                usleep(10_000)
                waits += 1
            }
            // A short duration of its own; left unset, it inherits the still stretch before it, which a join would play.
            let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 600), presentationTimeStamp: time, decodeTimeStamp: .invalid)
            if video.isReadyForMoreMediaData, let copy = try? CMSampleBuffer(copying: lastFrame, withNewTiming: [timing]) {
                video.append(copy)
            }
            writer.endSession(atSourceTime: time)
        }
        video.markAsFinished()
        audio?.markAsFinished()
        writer.finishWriting { [self] in
            if writer.status == .completed {
                completion(.success(url))
            } else {
                try? FileManager.default.removeItem(at: url)
                completion(.failure(writer.error ?? CocoaError(.fileWriteUnknown)))
            }
        }
    }

    // For a cancelled recording: stops writing and deletes the file.
    func discard() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func status(of buffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
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
    private var ticker: Timer?

    // `screen` is where what's being recorded is, so Start is nearby.
    init(model: StitchModel, on screen: NSScreen? = nil) {
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
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - panel.frame.height - 12))
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
        item.button?.contentTintColor = capturing ? .systemRed : nil
        if capturing, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMenuBarTitle() }
            }
        } else if !capturing {
            ticker?.invalidate()
            ticker = nil
        }
        updateMenuBarTitle()
    }

    private func updateMenuBarTitle() {
        guard let model else { return }
        item.button?.title = switch model.recordingState {
        case let .recording(since): "Stop · \(formatDuration(Date().timeIntervalSince(since)))"
        case let .countdown(remaining): "Cancel · \(remaining)"
        case .starting: "Starting…"
        default: "Start Recording"
        }
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
        ticker?.invalidate()
        ticker = nil
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
                        .strokeBorder(.secondary, lineWidth: 2)
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "Ready to record \(title)")
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let note = model.readyNote {
                            Text(verbatim: note)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Not recording yet. Click Start to begin.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
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
                if model.isWindowCovered {
                    Button("Bring to Front") { model.bringWindowToFront() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Put the window you picked in front of the others. If System Settings opens, turn on Screen Stitch there, then click again.")
                }
                Button("Change…") { model.changeTarget() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Pick a different window, display or area")
                Button("Cancel") { model.cancelReady() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                pill("Start", systemImage: "record.circle") { model.beginRecording() }
                    .help(model.useGlobalShortcuts ? "Start recording (\(model.recordCombo.label) from any app)" : "Start recording")
            case let .countdown(remaining):
                Text(verbatim: "Recording starts in \(remaining)…")
                    .font(.body.monospacedDigit().weight(.medium))
                    .padding(.leading, 6)
                    .windowDragHandle()
                Button("Cancel") { model.cancelCountdown() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
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
                            .fill(.white)
                            .frame(width: 10, height: 10)
                            .opacity(Int(elapsed) % 2 == 0 ? 1 : 0.35)
                        Text(verbatim: "REC \(formatDuration(elapsed))")
                            .font(.body.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.leading, 6)
                .windowDragHandle()
                pill("Stop", systemImage: "stop.fill", inverted: true) { model.stopRecording() }
                    .help(model.useGlobalShortcuts ? "Stop recording (\(model.recordCombo.label) from any app)" : "Stop recording")
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(model.isCapturing ? AnyShapeStyle(Color.red) : AnyShapeStyle(.regularMaterial), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
    }

    // A custom style because prominent buttons turn gray in a panel that never becomes key.
    private func pill(_ title: String, systemImage: String, inverted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(inverted ? Color.red : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(inverted ? Color.white : .red, in: Capsule())
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

// A big 3-2-1 in the middle of the screen being recorded, so it's obvious when recording begins.
@MainActor
final class CountdownOverlay {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")

    init(on screen: NSScreen) {
        let size: CGFloat = 200
        window = NSWindow(
            contentRect: NSRect(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2, width: size, height: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.canHide = false
        window.sharingType = .none

        let background = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        background.layer?.cornerRadius = 40
        label.font = .systemFont(ofSize: 120, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        background.addSubview(label)
        window.contentView = background
        window.orderFrontRegardless()
    }

    func show(_ number: Int) {
        label.stringValue = "\(number)"
        label.sizeToFit()
        let bounds = window.contentView?.bounds ?? .zero
        label.frame = NSRect(x: 0, y: (bounds.height - label.frame.height) / 2, width: bounds.width, height: label.frame.height)
    }

    func remove() {
        window.orderOut(nil)
    }
}

// A flat clapperboard. Its stick starts open and snaps shut on clap(after:).
final class ClapperView: NSView {
    private static let openAngle = 0.4
    private let stick: CALayer

    init(color: NSColor, stripes: NSColor) {
        stick = Self.board(CGRect(x: 0, y: 39, width: 60, height: 11), radius: 3, band: 2.5...8.5, slant: -5, color: color, stripes: stripes)
        super.init(frame: CGRect(x: 0, y: 0, width: 60, height: 54))
        wantsLayer = true
        layer?.addSublayer(Self.board(CGRect(x: 0, y: 0, width: 60, height: 36), radius: 5, band: 26...33, slant: 5, color: color, stripes: stripes))
        stick.anchorPoint = .zero
        stick.position = CGPoint(x: 0, y: 39)
        layer?.addSublayer(stick)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { frame.size }

    func open() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stick.setAffineTransform(CGAffineTransform(rotationAngle: Self.openAngle))
        CATransaction.commit()
    }

    func clap() {
        let close = CABasicAnimation(keyPath: "transform.rotation.z")
        close.fromValue = Self.openAngle
        close.toValue = 0
        close.duration = 0.12
        close.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stick.setAffineTransform(.identity)
        CATransaction.commit()
        stick.add(close, forKey: nil)
    }

    private static func board(_ rect: CGRect, radius: CGFloat, band: ClosedRange<CGFloat>, slant: CGFloat, color: NSColor, stripes: NSColor) -> CALayer {
        let board = CAShapeLayer()
        board.frame = rect
        board.path = CGPath(roundedRect: board.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        board.fillColor = color.cgColor
        let path = CGMutablePath()
        for x in stride(from: 7.0, to: rect.width - 12, by: 14) {
            path.addLines(between: [
                CGPoint(x: x, y: band.lowerBound), CGPoint(x: x + 8, y: band.lowerBound),
                CGPoint(x: x + 8 + slant, y: band.upperBound), CGPoint(x: x + slant, y: band.upperBound),
            ])
            path.closeSubpath()
        }
        let paint = CAShapeLayer()
        paint.frame = board.bounds
        paint.path = path
        paint.fillColor = stripes.cgColor
        board.addSublayer(paint)
        return board
    }
}

// A brief system-style HUD over what's being recorded when recording starts: a faint dim and a glass panel with a
// clapperboard that snaps shut, fading in and out like macOS's own HUDs. Like the other overlays it's left out of the
// recording.
@MainActor
final class Slate {
    private let window: NSWindow
    private let clapper = ClapperView(color: .white, stripes: NSColor(white: 0.22, alpha: 1))
    private let shownAt = CACurrentMediaTime()
    private var dismissed = false

    // Shows at once, with the stick open; clap() snaps it shut when recording actually begins, a moment later.
    init(over target: CGRect, clipNumber: Int) {
        let hudSize = CGSize(width: 180, height: 150)
        // Big enough for the panel even when the target is a small area.
        let frame = target.insetBy(
            dx: -max(0, (hudSize.width + 40 - target.width) / 2),
            dy: -max(0, (hudSize.height + 40 - target.height) / 2)
        )
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.canHide = false
        window.sharingType = .none
        window.alphaValue = 0

        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let dim = NSView(frame: target.offsetBy(dx: -frame.minX, dy: -frame.minY))
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        root.addSubview(dim)

        let title = NSTextField(labelWithString: "Recording")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        let subtitle = NSTextField(labelWithString: "Clip \(clipNumber)")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [clapper, title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(12, after: clapper)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: CGRect(origin: .zero, size: hudSize))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        let hudFrame = CGRect(
            x: (frame.width - hudSize.width) / 2, y: (frame.height - hudSize.height) / 2,
            width: hudSize.width, height: hudSize.height
        )
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: hudFrame)
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.cornerRadius = 26
            glass.tintColor = NSColor.black.withAlphaComponent(0.35)
            glass.contentView = content
            root.addSubview(glass)
        } else {
            let hud = NSVisualEffectView(frame: hudFrame)
            hud.material = .hudWindow
            hud.blendingMode = .behindWindow
            hud.state = .active
            hud.appearance = NSAppearance(named: .vibrantDark)
            hud.wantsLayer = true
            hud.layer?.cornerRadius = 22
            hud.layer?.masksToBounds = true
            hud.addSubview(content)
            root.addSubview(hud)
        }
        window.contentView = root
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clapper.open()
        }
        // In case recording never starts and nobody says so.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.dismiss()
        }
    }

    // Waits for the fade-in to finish, so the snap is seen.
    func clap() {
        let wait = max(0, shownAt + 0.2 - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                clapper.clap()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                dismiss()
            }
        }
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            window.orderOut(nil)
        })
    }
}

// Dims every screen and lets the user drag out a rectangle, which is used as soon as they let go. Reports the screen
// and the rectangle in that screen's coordinates (points, bottom-left origin), or nil if they press Esc. Moving and
// resizing it afterwards is AreaEditor's job.
@MainActor
final class AreaSelector {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        var onBegin: (() -> Void)?
        var onConfirm: ((CGRect) -> Void)?
        private var selection: CGRect?
        private var origin: CGPoint?

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func clear() {
            selection = nil
            origin = nil
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            onBegin?()
            window?.makeKey()
            origin = convert(event.locationInWindow, from: nil)
            selection = nil
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let point = convert(event.locationInWindow, from: nil)
            let rect = CGRect(
                x: min(origin.x, point.x), y: min(origin.y, point.y),
                width: abs(point.x - origin.x), height: abs(point.y - origin.y)
            )
            selection = rect.intersection(bounds).integral
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            origin = nil
            if let selection, selection.width >= AreaGeometry.minimumSize, selection.height >= AreaGeometry.minimumSize {
                onConfirm?(selection)
            } else {
                clear()
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            guard let selection else {
                let hint = "Drag to select the area to record. Press Esc to cancel." as NSString
                let size = hint.size(withAttributes: attributes)
                hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
                return
            }
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5)).stroke()
            let label = "\(Int(selection.width))×\(Int(selection.height))" as NSString
            let size = label.size(withAttributes: attributes)
            let above = selection.maxY + 8
            label.draw(at: CGPoint(x: selection.minX, y: above + size.height < bounds.maxY ? above : selection.maxY - size.height - 8), withAttributes: attributes)
        }
    }

    private var overlays: [(screen: NSScreen, window: OverlayWindow, view: SelectionView)] = []
    private var keyMonitor: Any?
    private let completion: ((screen: NSScreen, rect: CGRect)?) -> Void

    init(completion: @escaping ((screen: NSScreen, rect: CGRect)?) -> Void) {
        self.completion = completion
        NSApp.activate()
        NSCursor.crosshair.set()
        // Esc cancels whichever overlay is key, or none if activation hasn't landed yet.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.finish(nil) }
            return nil
        }
        let mouse = NSEvent.mouseLocation
        let keyScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onBegin = { [weak self, weak view] in self?.clearSelections(except: view) }
            view.onConfirm = { [weak self] rect in self?.finish((screen, rect)) }
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            if screen == keyScreen {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
            } else {
                window.orderFrontRegardless()
            }
            overlays.append((screen, window, view))
        }
    }

    private func clearSelections(except keep: SelectionView?) {
        for overlay in overlays where overlay.view !== keep {
            overlay.view.clear()
        }
    }

    func cancel() {
        finish(nil)
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

// Start, or the time and Stop while recording, next to what's being recorded so it's close at hand. Like the other
// overlays it's left out of recordings. It goes below the target, or nowhere when there's no room there, unless it
// may sit just inside the target's bottom edge instead.
@MainActor
final class TargetPill {
    enum Mode: Equatable {
        case ready(size: CGSize?)
        case recording(since: Date)
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
    }

    private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private struct Content: View {
        let mode: Mode
        let now: Date
        let start: () -> Void
        let stop: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                switch mode {
                case let .ready(size):
                    if let size {
                        Text(verbatim: "\(Int(size.width))×\(Int(size.height))")
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    button("Start", systemImage: "record.circle", action: start)
                        .help("Start recording")
                case let .recording(since):
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Recording")
                    Text(verbatim: formatDuration(now.timeIntervalSince(since)))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    button("Stop", systemImage: "stop.fill", action: stop)
                        .help("Stop recording")
                }
            }
            .padding(.leading, mode == .ready(size: nil) ? 4 : 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.65), in: Capsule())
            .fixedSize()
        }

        private func button(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: systemImage)
                    Text(title)
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.red, in: Capsule())
        }
    }

    // Clears the frame drawn around the target.
    nonisolated static let gap: CGFloat = 16

    private let panel: Panel
    private let host: FirstClickHostingView<Content>
    private let start: () -> Void
    private let stop: () -> Void
    private var mode: Mode
    private var placement: (target: CGRect, gap: CGFloat, screen: CGRect, insideIfNeeded: Bool)?
    private var clock: Timer?

    init(start: @escaping () -> Void, stop: @escaping () -> Void) {
        self.start = start
        self.stop = stop
        mode = .ready(size: nil)
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.canHide = false
        panel.sharingType = .none
        host = FirstClickHostingView(rootView: Content(mode: mode, now: Date(), start: start, stop: stop))
        panel.contentView = host
    }

    // Centered `gap` below `target` and inside `screen`, or just inside the target's bottom edge when `insideIfNeeded`.
    // Nil when neither fits.
    nonisolated static func origin(for size: CGSize, below target: CGRect, gap: CGFloat, within screen: CGRect, insideIfNeeded: Bool) -> CGPoint? {
        var origin = CGPoint(x: target.midX - size.width / 2, y: target.minY - gap - size.height)
        if origin.y < screen.minY + 4 {
            guard insideIfNeeded else { return nil }
            origin.y = target.minY + gap
        }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        return origin
    }

    func show(_ mode: Mode, below target: CGRect, gap: CGFloat = gap, within screen: CGRect, insideIfNeeded: Bool) {
        placement = (target, gap, screen, insideIfNeeded)
        if mode != self.mode {
            self.mode = mode
            host.rootView = Content(mode: mode, now: Date(), start: start, stop: stop)
        }
        if case .recording = mode, clock == nil {
            let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(clock, forMode: .common)
            self.clock = clock
        }
        place()
    }

    // A wider time would otherwise grow the pill to the right.
    private func tick() {
        host.rootView = Content(mode: mode, now: Date(), start: start, stop: stop)
        place()
    }

    private func place() {
        guard let placement else { return }
        let size = host.fittingSize
        guard let origin = Self.origin(for: size, below: placement.target, gap: placement.gap, within: placement.screen,
                                       insideIfNeeded: placement.insideIfNeeded) else {
            panel.orderOut(nil)
            return
        }
        let frame = CGRect(origin: origin, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        clock?.invalidate()
        clock = nil
        placement = nil
        panel.orderOut(nil)
    }
}

// A shortcut's key and modifiers, in the form Carbon's hot key API takes them. `key` is what the key types, for showing.
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt32
    var key: String

    static let recordDefault = KeyCombo(keyCode: kVK_ANSI_R, modifiers: UInt32(controlKey | optionKey), key: "R")
    static let showDefault = KeyCombo(keyCode: kVK_ANSI_S, modifiers: UInt32(controlKey | optionKey), key: "S")

    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
    private static let namedKeys: [Int: String] = {
        var names = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        for (index, keyCode) in functionKeys.enumerated() {
            names[keyCode] = "F\(index + 1)"
        }
        return names
    }()

    init(keyCode: Int, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let keyCode = Int(event.keyCode)
        let typed = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        self.init(keyCode: keyCode, modifiers: modifiers, key: Self.namedKeys[keyCode] ?? (typed.isEmpty ? "?" : typed))
    }

    // In the order macOS menus use.
    var label: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }
            .map(\.1)
            .joined() + key
    }

    // A global shortcut takes its keys away from every app, so it needs two modifiers; with one it would take a common
    // command, or a character people type. Function keys can go without.
    var isAllowed: Bool {
        let count = [controlKey, optionKey, shiftKey, cmdKey].filter { modifiers & UInt32($0) != 0 }.count
        return Self.functionKeys.contains(keyCode) || count >= 2
    }

    func matches(_ other: KeyCombo) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    // macOS's own shortcuts that are turned on, like ⇧⌘5 for the screenshot toolbar. They beat any app's, and macOS
    // still lets an app register the same keys, which then never arrive.
    static func systemShortcuts() -> [KeyCombo] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let hotKeys = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let mask = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return hotKeys.compactMap { hotKey in
            guard hotKey[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let keyCode = hotKey[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = hotKey[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }
            return KeyCombo(keyCode: keyCode, modifiers: UInt32(modifiers) & mask, key: "")
        }
    }
}

// System-wide shortcuts through Carbon's hot keys, which need no permission. They work while the app runs, even
// hidden, which is the point: the window is hidden while recording.
@MainActor
final class GlobalHotKeys {
    struct Shortcut {
        let keyCode: Int
        let modifiers: UInt32
        let label: String
        let action: () -> Void
    }

    private let signature: OSType
    private var registered: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    init(signature: OSType) {
        self.signature = signature
    }

    // The handler holds an unretained pointer to this object.
    deinit {
        registered.forEach { UnregisterEventHotKey($0) }
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    // Returns the labels of shortcuts that couldn't be registered, usually because another app holds them.
    func register(_ shortcuts: [Shortcut]) -> [String] {
        unregister()
        if handler == nil {
            installHandler()
        }
        var failed: [String] = []
        for (index, shortcut) in shortcuts.enumerated() {
            let id = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
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
            let handled = MainActor.assumeIsolated { hotKeys.handle(id) }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    // Each instance installs its own handler, so one passes on the other's keys.
    private func handle(_ id: EventHotKeyID) -> Bool {
        guard id.signature == signature, let action = actions[id.id] else { return false }
        action()
        return true
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
                    Text("Screen Stitch uses FFmpeg to combine and compress clips. Install it with Homebrew (`brew install ffmpeg`), then click Quit & Reopen.")
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
                Text("The finished video is a small MP4 that's easy to share.")
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
                Text(verbatim: "Press \(model.recordCombo.label) in any app to choose what to record, then again to start and again to stop.")
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

    // The path opens a menu, as a path in the Finder does. The menu brings its own padding, which stands in for a space.
    var body: some View {
        HStack(spacing: 0) {
            Text("Recordings save to")
                .foregroundStyle(.secondary)
            Menu {
                Button("Show in Finder") { model.showRecordingsFolder() }
                Button("Change Folder…") { model.chooseRecordingsFolder() }
            } label: {
                Text(verbatim: displayPath(model.recordingsFolder))
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .linkColor))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("Show the recordings folder in the Finder, or choose a different one")
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
                step(3, "When you're done, click Stop in the floating bar at the top of the screen. Stop is also in the menu bar. The recording is added to this session.")
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
                    Text("Pick a window, display or area. Recording starts when you click Start in the floating bar, which appears at the top of the screen.")
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
                    .help("Adds your voice, not the sound your Mac plays. You can also change it in the floating bar before you click Start.")
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
                            section("Windows", model.targets.filter { !$0.isDisplay && $0.offScreenReason == nil }, includingArea: false)
                            section("Not on Screen", model.targets.filter { !$0.isDisplay && $0.offScreenReason != nil }, includingArea: false)
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
                    } else if let reason = target.offScreenReason {
                        VStack(spacing: 8) {
                            if let icon = target.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 48, height: 48)
                            }
                            Text(verbatim: reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
        .help(target.offScreenReason == nil ? "Choose \(target.phrase)" : "Choose \(target.phrase). Screen Stitch will try to bring it back.")
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
                    Text(verbatim: displayPath(model.recordingsFolder))
                    HStack {
                        Button("Change…") { model.chooseRecordingsFolder() }
                        Button("Show in Finder") { model.showRecordingsFolder() }
                        if model.recordingsFolder != StitchModel.defaultRecordingsFolder {
                            Button("Use Default") { model.recordingsFolder = StitchModel.defaultRecordingsFolder }
                        }
                    }
                }
            }
            captioned("Adds your voice to new recordings. Sound your Mac plays isn't recorded.") {
                Toggle("Record Microphone", isOn: Binding(get: { model.recordMicrophone }, set: { model.recordMicrophone = $0 }))
            }
            captioned("Appears for about a second and isn't recorded.") {
                Toggle("Briefly show “Recording” when recording starts", isOn: Binding(
                    get: { model.showsSlate },
                    set: { model.showsSlate = $0 }
                ))
            }
            captioned("Gives you a moment to get ready. The countdown isn't recorded.") {
                Toggle("Count down 3-2-1 before recording", isOn: Binding(
                    get: { model.countsDownBeforeRecording },
                    set: { model.countsDownBeforeRecording = $0 }
                ))
            }
            LabeledContent("Shortcuts") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Use from any app", isOn: Binding(get: { model.useGlobalShortcuts }, set: { model.useGlobalShortcuts = $0 }))
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            ShortcutField(action: .record)
                            Text("Press once to get ready, again to start, again to stop")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        GridRow {
                            ShortcutField(action: .show)
                            Text("Show Screen Stitch")
                        }
                    }
                    .disabled(!model.useGlobalShortcuts)
                    if let hint = model.shortcutHint {
                        Text(verbatim: hint)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem = model.shortcutProblem {
                        Text(verbatim: problem)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.shortcutClashesWithMacOS {
                            Button("Open Keyboard Settings…") { model.openKeyboardShortcutSettings() }
                        }
                    }
                    Text("Click a shortcut, then press the keys you want. The shortcuts work while Screen Stitch is open, even if another app is in front.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.recordCombo != .recordDefault || model.showCombo != .showDefault {
                        Button("Use Defaults") { model.useDefaultShortcuts() }
                            .disabled(!model.useGlobalShortcuts)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { model.updateGlobalShortcuts() }
        .onDisappear { model.endEditingShortcut() }
    }

    private func captioned(_ caption: LocalizedStringKey, @ViewBuilder toggle: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            toggle()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }
}

// Shows a global shortcut; click it, then press new keys.
struct ShortcutField: View {
    @Environment(StitchModel.self) private var model
    let action: StitchModel.ShortcutAction

    var body: some View {
        let editing = model.editingShortcut == action
        Button {
            model.editShortcut(action)
        } label: {
            Text(verbatim: editing ? "Press keys…" : model.combo(for: action).label)
                .foregroundStyle(editing ? Color.accentColor : .primary)
                .frame(minWidth: 64)
        }
        .help(editing ? "Press the keys you want, or Esc to cancel" : "Click, then press the keys you want")
    }
}

struct ClipList: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ClipListHeader()
            Divider()
            let numbers = Dictionary(uniqueKeysWithValues: model.clips.enumerated().map { ($1.id, $0 + 1) })
            List(selection: $model.selection) {
                ForEach(model.items) { item in
                    switch item {
                    case let .clip(clip):
                        ClipRow(number: numbers[clip.id] ?? 0, clip: clip)
                    case let .card(card):
                        TitleCardRow(card: card)
                    }
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
            Text(verbatim: model.clips.count == 1 ? "Session · 1 clip" : "Session · \(model.clips.count) clips")
                .font(.headline)
            Text(model.isDateOrdered ? "In recording order. Drag to reorder." : "Custom order. New clips go at the end.")
                .foregroundStyle(.secondary)
            Spacer()
            Menu("Title Cards") {
                if model.hasBeforeAndAfter || model.canAddBeforeAndAfter {
                    Toggle("Before & After", isOn: Binding(get: { model.hasBeforeAndAfter }, set: { _ in model.toggleBeforeAndAfter() }))
                }
                Button("Add Title Card") { model.addTitleCard() }
            }
            .fixedSize()
            .help("Add text shown between clips in the combined video")
            Button("Sort by Date") { model.sortByDate() }
                .disabled(model.isDateOrdered || model.clips.count < 2)
                .help("Put the clips back in the order they were recorded")
            Button("Clear Session") { model.clearSession() }
                .help("Start a new session. You can choose to move its files to the Trash.")
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
            if model.lastTarget == nil {
                Button { model.startRecording() } label: {
                    Label("Record Screen", systemImage: "record.circle")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .fixedSize()
            } else {
                RecordSplitButton()
            }
            LastTargetLine()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .disabled(model.isEncoding || model.isRecording)
    }
}

// Record Another with an arrow for Record Something Else…. SwiftUI's own split button (a Menu with a primary action)
// stays grey whatever its tint, so this one is drawn to the same size in red.
struct RecordSplitButton: View {
    @Environment(StitchModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            Button { model.startRecording() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle")
                    Text("Record Another")
                }
                .padding(.horizontal, 13)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Record the same thing again")
            Rectangle()
                .fill(.white.opacity(0.35))
                .frame(width: 1, height: 16)
            Menu {
                Button("Record Something Else…") { model.pickTarget() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 28)
            .padding(.trailing, 3)
            .help("Record something else")
        }
        .foregroundStyle(.white)
        .background(Color.red, in: Capsule())
        .opacity(isEnabled ? 1 : 0.5)
        .fixedSize()
    }
}

// What Record Another will record. The label is secondary and the target primary, so the eye lands on the target.
struct LastTargetLine: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        if case let .window(_, pid, title)? = model.lastTarget {
            let app = NSRunningApplication(processIdentifier: pid)
            HStack(spacing: 6) {
                Text("Same as last time:")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if let icon = app?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(app?.localizedName.map { $0 == title ? $0 : "\($0): \(title)" } ?? title)
        } else if let last = model.lastTarget {
            HStack(spacing: 6) {
                Text("Same as last time:")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(verbatim: last.phrase)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text("Pick a window, display or area to record. The recording is added to this session when you stop.")
                .foregroundStyle(.secondary)
        }
    }
}

// A video's thumbnail with a play button, cropped to fill its box.
struct PreviewThumbnail: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 54)
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
}

// A title card in the list: its text, how long it shows, and white on black or black on white.
struct TitleCardRow: View {
    @Environment(StitchModel.self) private var model
    let card: TitleCard

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "textformat")
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            ZStack {
                card.isLight ? Color.white : Color.black
                Text(verbatim: card.text)
                    .font(.system(size: 10, weight: .medium, design: .serif))
                    .foregroundStyle(card.isLight ? Color.black : Color.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(6)
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: Binding(get: { card.text }, set: { text in model.updateCard(card.id) { $0.text = text } }))
                    .textFieldStyle(.roundedBorder)
                Text("Title card")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // Typed or stepped by a quarter second; kept to two decimals and within the allowed range.
            let seconds = Binding<Double>(get: { card.duration }, set: { value in
                let rounded = (value * 100).rounded() / 100
                model.updateCard(card.id) { $0.duration = min(max(rounded, TitleCard.durations.lowerBound), TitleCard.durations.upperBound) }
            })
            HStack(spacing: 4) {
                TextField("Seconds", value: seconds, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Text("sec")
                    .foregroundStyle(.secondary)
                Stepper("Seconds", value: seconds, in: TitleCard.durations, step: 0.25)
                    .labelsHidden()
            }
            .fixedSize()
            .help("How long the card shows, from 0.25 to 10 seconds")
            Picker("Style", selection: Binding(get: { card.isLight }, set: { light in model.updateCard(card.id) { $0.isLight = light } })) {
                Text("Dark").tag(false)
                Text("Light").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("White text on black, or black text on white")
            Button {
                model.remove(item: card.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Remove from List")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Remove from List") { model.remove(item: card.id) }
        }
    }
}

struct ClipRow: View {
    @Environment(StitchModel.self) private var model
    let number: Int
    let clip: Clip

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            Button {
                model.preview(clip)
            } label: {
                PreviewThumbnail(image: model.thumbnails[clip.id])
            }
            .buttonStyle(.plain)
            .help("Preview")
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
                .help("The video's maximum size; 1080p suits most uses. Clips smaller than the video aren't enlarged. They're centered with black bars around them.")
                Picker("Quality", selection: $settings.quality) {
                    ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .help("Higher quality makes a larger file")
                if model.canCombineWithoutCompressing {
                    Menu {
                        Button("Combine Without Compressing…") { model.chooseOutputAndEncode(compressing: false) }
                    } label: {
                        Text("Combine & Compress…")
                    } primaryAction: {
                        model.chooseOutputAndEncode()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(model.isProbing)
                } else {
                    Button(model.clips.count == 1 ? "Compress…" : "Combine & Compress…") { model.chooseOutputAndEncode() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.clips.isEmpty || model.isProbing)
                }
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
            HStack(spacing: 14) {
                Button {
                    model.previewOutput()
                } label: {
                    PreviewThumbnail(image: model.outputThumbnail)
                }
                .buttonStyle(.plain)
                .help("Preview the saved video")
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(verbatim: "Saved \(output.lastPathComponent) · \(formatBytes(outputBytes))\(savings(outputBytes, inputBytes))")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    HStack(spacing: 8) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                        Button("Open") { NSWorkspace.shared.open(output) }
                        Spacer(minLength: 16)
                        Button("Clear Session") { model.clearSession() }
                            .buttonStyle(.borderedProminent)
                            .help("Start a new session. You can choose to move its files to the Trash.")
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
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

// "Movies › Screen Stitch" for folders in the home folder.
func displayPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
    let parts = url.standardizedFileURL.pathComponents
    let shown = parts.starts(with: home) ? parts.dropFirst(home.count) : parts.dropFirst()
    return shown.isEmpty ? abbreviatedPath(url) : shown.joined(separator: " › ")
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
