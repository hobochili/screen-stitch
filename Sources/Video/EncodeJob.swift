import Foundation

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
