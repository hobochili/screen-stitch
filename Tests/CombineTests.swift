import Foundation
import Testing

@Suite(.enabled(if: tools != nil, "needs FFmpeg"))
struct CombineTests {
    private final class Progress: @unchecked Sendable {
        var latest = 0.0
    }

    private func combine(_ urls: [URL], size: OutputSize, to output: URL, joining: Bool = false) async throws -> Double {
        let clips = try urls.map { try Prober.probe($0, ffprobe: tools!.ffprobe) }
        var job = EncodeJob(clips: clips, size: size, quality: .standard, output: output)
        if joining {
            let list = output.deletingLastPathComponent().appendingPathComponent("list.txt")
            try job.concatList.write(to: list, atomically: true, encoding: .utf8)
            job.mode = .join(list: list)
        }
        let progress = Progress()
        let (status, errors) = try await withCheckedThrowingContinuation { continuation in
            do {
                try FFmpegRun().start(
                    ffmpeg: tools!.ffmpeg,
                    arguments: job.arguments,
                    duration: job.duration,
                    onProgress: { progress.latest = $0 },
                    onExit: { continuation.resume(returning: ($0, $1)) }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(status == 0, "\(errors)")
        return progress.latest
    }

    @Test func mismatchedClipsAreCenteredInOneFrame() async throws {
        let folder = try TemporaryFolder()
        let wide = folder.file("1 wide.mov")
        let small = folder.file("2 small.mov")
        let tall = folder.file("3 tall.mov")
        try makeVideo(wide, width: 640, height: 360, audio: true)
        try makeVideo(small, width: 320, height: 240, color: "white")
        try makeVideo(tall, width: 360, height: 640, color: "yellow", audio: true)
        let output = folder.file("combined.mp4")

        let progress = try await combine([wide, small, tall], size: .original, to: output)

        let info = try videoInfo(output)
        #expect(info.width == 640 && info.height == 640)
        #expect(abs(info.duration - 3) < 0.15)
        #expect(info.audioChannels == 2 && info.audioSampleRate == 48000)
        #expect(try visibleArea(of: output, at: 0.5) == "640:360:0:140")
        #expect(try visibleArea(of: output, at: 1.5) == "320:240:160:200")
        #expect(try visibleArea(of: output, at: 2.5) == "360:640:140:0")
        #expect(progress > 0.9)
    }

    @Test func smallerClipKeepsItsSizeUnderTheCap() async throws {
        let folder = try TemporaryFolder()
        let big = folder.file("1 big.mov")
        let small = folder.file("2 small.mov")
        try makeVideo(big, width: 1280, height: 720)
        try makeVideo(small, width: 640, height: 360, color: "white")
        let output = folder.file("combined.mp4")
        _ = try await combine([big, small], size: .p720, to: output)
        #expect(try videoInfo(output).height == 720)
        #expect(try visibleArea(of: output, at: 1.5) == "640:360:320:180")
    }

    // Scaling the frame to half size halves the small clip too, so everything stays in proportion.
    @Test func cappedFrameScalesEveryClip() async throws {
        let folder = try TemporaryFolder()
        let huge = folder.file("1 huge.mov")
        let small = folder.file("2 small.mov")
        try makeVideo(huge, width: 2560, height: 1440)
        try makeVideo(small, width: 640, height: 360, color: "white")
        let output = folder.file("combined.mp4")
        _ = try await combine([huge, small], size: .p720, to: output)
        let info = try videoInfo(output)
        #expect(info.width == 1280 && info.height == 720)
        #expect(try visibleArea(of: output, at: 1.5) == "320:180:480:270")
    }

    @Test func silentClipsMakeSilentVideo() async throws {
        let folder = try TemporaryFolder()
        let first = folder.file("1.mov")
        let second = folder.file("2.mov")
        try makeVideo(first, width: 320, height: 240)
        try makeVideo(second, width: 320, height: 240)
        let output = folder.file("combined.mp4")
        _ = try await combine([first, second], size: .original, to: output)
        #expect(try videoInfo(output).audioChannels == nil)
    }

    @Test func joiningKeepsEveryFrameAndTheSound() async throws {
        let folder = try TemporaryFolder()
        let first = folder.file("1 first's.mov")
        let second = folder.file("2 second.mov")
        try makeVideo(first, width: 320, height: 240, seconds: 2, audio: true)
        try makeVideo(second, width: 320, height: 240, seconds: 3, color: "white", audio: true)
        let output = folder.file("joined.mp4")
        _ = try await combine([first, second], size: .p720, to: output, joining: true)
        let info = try videoInfo(output)
        #expect(info.width == 320 && info.height == 240)
        #expect(abs(info.duration - 5) < 0.1)
        #expect(info.audioChannels != nil)
        let frames = try run(tools!.ffprobe, ["-v", "error", "-count_frames", "-select_streams", "v", "-show_entries",
                                               "stream=nb_read_frames", "-of", "csv=p=0", output.path])
        #expect(frames.trimmingCharacters(in: .whitespacesAndNewlines) == "150")
        #expect(try visibleArea(of: output, at: 1) == "320:240:0:0")
    }

    // Camera videos often carry a timecode track; joining copies only the picture and sound.
    @Test func joiningIgnoresTimecodeTracks() async throws {
        let folder = try TemporaryFolder()
        let first = folder.file("1.mov")
        let second = folder.file("2.mov")
        try makeVideo(first, width: 320, height: 240, audio: true, options: ["-timecode", "00:00:00:00"])
        try makeVideo(second, width: 320, height: 240, color: "white", audio: true, options: ["-timecode", "00:00:01:00"])
        let output = folder.file("joined.mp4")
        _ = try await combine([first, second], size: .original, to: output, joining: true)
        #expect(abs(try videoInfo(output).duration - 2) < 0.1)
    }
}

@MainActor
@Suite(.enabled(if: tools != nil, "needs FFmpeg"), .serialized)
struct EncodeCleanupTests {
    private func model(with urls: [URL]) throws -> StitchModel {
        let model = StitchModel()
        model.useGlobalShortcuts = false
        model.items = try urls.map { .clip(try Prober.probe($0, ffprobe: tools!.ffprobe)) }
        return model
    }

    private func waitWhileEncoding(_ model: StitchModel) async throws {
        var waited = 0
        while model.isEncoding, waited < 400 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }

    // FFmpeg fails before writing anything, so the file the user chose to replace is left alone.
    @Test func failedRunKeepsTheFileItWasReplacing() async throws {
        let folder = try TemporaryFolder()
        let input = folder.file("clip.mov")
        try makeVideo(input, width: 320, height: 240)
        let model = try model(with: [input])
        try FileManager.default.removeItem(at: input)
        let output = folder.file("existing.mp4")
        try Data("keep me".utf8).write(to: output)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: output.path)
        model.encode(to: output)
        try await waitWhileEncoding(model)
        guard case .failed = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func cancellingRemovesThePartialFile() async throws {
        let folder = try TemporaryFolder()
        let input = folder.file("long.mov")
        try makeVideo(input, width: 1920, height: 1080, seconds: 60)
        let model = try model(with: [input])
        let output = folder.file("partial.mp4")
        model.encode(to: output)
        var waited = 0
        while !FileManager.default.fileExists(atPath: output.path), waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        model.cancel()
        try await waitWhileEncoding(model)
        #expect(model.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    // A dark card between two clips, with sound throughout, as the model builds it.
    @Test func titleCardsBecomeFramesOfText() async throws {
        let folder = try TemporaryFolder()
        let first = folder.file("1.mov")
        let second = folder.file("2.mov")
        try makeVideo(first, width: 640, height: 360, color: "white", audio: true)
        try makeVideo(second, width: 640, height: 360, color: "white", audio: true)
        let model = try model(with: [first, second])
        model.items.insert(.card(TitleCard(text: "After…", duration: 2)), at: 1)
        let output = folder.file("with card.mp4")
        model.encode(to: output)
        try await waitWhileEncoding(model)
        guard case .done = model.state else {
            Issue.record("expected a finished video, got \(model.state)")
            return
        }
        let info = try videoInfo(output)
        #expect(abs(info.duration - 4) < 0.15)
        #expect(info.audioChannels == 2)
        // White clips around a dark card: bright, dark, bright.
        #expect(try averageBrightness(of: output, at: 0.5) > 200)
        #expect(try averageBrightness(of: output, at: 2.0) < 60)
        #expect(try averageBrightness(of: output, at: 3.5) > 200)
    }
}

