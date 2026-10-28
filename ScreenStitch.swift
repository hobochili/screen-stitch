import AppKit
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
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = StitchModel()

    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
    case small = "Small"

    var id: String { rawValue }

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

// MARK: - Model

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
    var clips: [Clip] = []
    var outputSize: OutputSize = .p1080
    var quality: Quality = .standard
    var state: EncodeState = .idle
    var progress = 0.0
    var notice: String?
    var isDropTargeted = false
    var watchFolder: URL?

    private var probing: Set<URL> = []
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
    var isEncoding: Bool { state == .encoding }
    var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } }
    var totalBytes: Int64 { clips.reduce(0) { $0 + $1.fileSize } }

    var summary: String {
        guard !clips.isEmpty else { return "" }
        let (width, height) = EncodeJob.canvas(for: clips, size: outputSize)
        let count = clips.count == 1 ? "1 video" : "\(clips.count) videos"
        return "\(count) · \(formatDuration(totalDuration)) · \(formatBytes(totalBytes)) → \(width)×\(height)"
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
        panel.message = "Choose screen recordings to combine"
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
            var skipped: [String] = []
            for (url, clip) in results {
                if let clip {
                    clips.append(clip)
                } else {
                    skipped.append(url.lastPathComponent)
                }
            }
            sortByDate()
            notice = skipped.isEmpty ? nil : "Skipped (not a readable video): \(skipped.sorted().joined(separator: ", "))"
        }
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
        panel.message = "Choose the folder your screen recordings are saved to"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        startWatching(in: folder)
    }

    // A file is added once its size stops changing, so recordings still being written are skipped until finished.
    private func checkWatchFolder() {
        guard let folder = watchFolder, !isEncoding else { return }
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

    func remove(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        clearResult()
    }

    func move(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
        clearResult()
    }

    func sortByDate() {
        clips.sort(by: Clip.chronological)
    }

    func clear() {
        clips = []
        notice = nil
        clearResult()
    }

    func chooseOutputAndEncode() {
        guard let first = clips.first else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = first.url.deletingLastPathComponent()
        panel.nameFieldStringValue = first.url.deletingPathExtension().lastPathComponent + " combined.mp4"
        guard panel.runModal() == .OK, let output = panel.url?.standardizedFileURL else { return }
        guard !clips.contains(where: { $0.url == output }) else {
            state = .failed("That file is one of the videos being combined. Choose a different name.")
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
            state = .failed(errors.isEmpty ? "ffmpeg exited with status \(status)." : "ffmpeg failed:\n\(errors)")
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
                    Label("ffmpeg not found", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Screen Stitch uses ffmpeg to join and compress videos. Install it with `brew install ffmpeg`, then reopen the app.")
                }
            } else if model.clips.isEmpty, let folder = model.watchFolder {
                ContentUnavailableView {
                    Label("Waiting for screen recordings", systemImage: "eye")
                } description: {
                    Text(verbatim: "Record with ⇧⌘5. New recordings saved to \(folder.lastPathComponent) show up here.")
                } actions: {
                    Button("Choose Videos…") { model.chooseFiles() }
                }
            } else if model.clips.isEmpty {
                ContentUnavailableView {
                    Label("Drop screen recordings here", systemImage: "film.stack")
                } description: {
                    Text("They're joined oldest to newest and compressed into one MP4.")
                } actions: {
                    Button("Choose Videos…") { model.chooseFiles() }
                    Button("Watch for New Recordings") { model.startWatching() }
                }
            } else {
                ClipList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                BottomBar()
            }
            .background(.background)
        }
        .frame(minWidth: 700, minHeight: 420)
        .overlay {
            if model.isProbing {
                ProgressView("Reading videos…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
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
        .toolbar {
            let locked = model.isEncoding || model.tools == nil
            ToolbarItemGroup {
                Toggle(isOn: Binding(get: { model.isWatching }, set: { $0 ? model.startWatching() : model.stopWatching() })) {
                    Label("Watch for Recordings", systemImage: "eye")
                }
                .help(model.isWatching ? "Stop watching for new recordings" : "Add new screen recordings as they're saved")
                Button("Add Videos", systemImage: "plus") { model.chooseFiles() }
                    .help("Add videos")
                    .disabled(locked)
                Button("Sort by Date", systemImage: "arrow.up.arrow.down") { model.sortByDate() }
                    .help("Sort oldest to newest")
                    .disabled(locked || model.clips.count < 2)
                Button("Clear", systemImage: "trash") { model.clear() }
                    .help("Remove all videos")
                    .disabled(locked || model.clips.isEmpty)
            }
        }
    }
}

struct ClipList: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        List {
            ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                ClipRow(index: index, clip: clip)
            }
            .onMove { model.move(from: $0, to: $1) }
        }
        .disabled(model.isEncoding)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: clip.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            .help("Remove")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            Button("Remove") { model.remove(clip) }
        }
    }
}

struct BottomBar: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        @Bindable var settings = model
        VStack(alignment: .leading, spacing: 12) {
            StatusView()
            if let folder = model.watchFolder {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                    Text(verbatim: "Adding new recordings from \(folder.lastPathComponent) as they're saved")
                    Button("Change…") { model.chooseWatchFolder() }
                        .buttonStyle(.link)
                    Button("Stop") { model.stopWatching() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let notice = model.notice {
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Text(verbatim: model.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Picker("Size", selection: $settings.outputSize) {
                    ForEach(OutputSize.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Picker("Quality", selection: $settings.quality) {
                    ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Button("Combine & Compress…") { model.chooseOutputAndEncode() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.clips.isEmpty || model.isProbing)
            }
            .disabled(model.isEncoding || model.tools == nil)
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
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(verbatim: "Saved \(output.lastPathComponent) · \(formatBytes(outputBytes))\(savings(outputBytes, inputBytes))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                Button("Open") { NSWorkspace.shared.open(output) }
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
                guard let value = iterator.next(), let parsed = Quality(rawValue: value.capitalized) else { usage() }
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
        log("Wrote \(output.path) (\(formatBytes(Int64(bytes))) from \(formatBytes(clips.reduce(0) { $0 + $1.fileSize })))")
        exit(0)
    }

    private static func usage() -> Never {
        fail("usage: ScreenStitch --cli [--size original|1440|1080|720] [--quality high|standard|small] OUTPUT.mp4 INPUT...")
    }

    private static func fail(_ message: String) -> Never {
        log(message)
        exit(1)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
