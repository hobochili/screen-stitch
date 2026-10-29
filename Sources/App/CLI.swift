import Foundation

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
