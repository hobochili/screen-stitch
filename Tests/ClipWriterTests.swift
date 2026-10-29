import AVFoundation
import Foundation
import ScreenCaptureKit
import Testing

// Feeds ClipWriter made-up frames and microphone audio shaped like ScreenCaptureKit's, so it runs without Screen
// Recording permission or a microphone.
@Suite(.enabled(if: tools != nil, "needs FFmpeg"))
struct ClipWriterTests {
    private static let start = CMTime(seconds: 1000, preferredTimescale: 600)

    private static func time(_ seconds: Double) -> CMTime {
        CMTimeAdd(start, CMTime(seconds: seconds, preferredTimescale: 48_000))
    }

    private static func frame(at seconds: Double, status: SCFrameStatus = .complete) -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels!, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time(seconds), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels!, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &buffer)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer!, createIfNecessary: true)! as NSArray
        (attachments[0] as! NSMutableDictionary)[SCStreamFrameInfo.status.rawValue] = status.rawValue
        return buffer!
    }

    private static func sound(at seconds: Double, frames: Int, format: AVAudioFormat) -> CMSampleBuffer {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<frames {
                pcm.floatChannelData![channel][index] = Float(sin(Double(index) / format.sampleRate * 2 * .pi * 440)) * 0.3
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
                                        presentationTimeStamp: time(seconds), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: format.formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)
        CMSampleBufferSetDataBufferFromAudioBufferList(buffer!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                       flags: 0, bufferList: pcm.audioBufferList)
        return buffer!
    }

    // Frames at 30 a second from `from` to `to`, with microphone audio in between if a format is given. The pause keeps
    // the encoder from falling behind, which would drop frames.
    private static func record(_ writer: ClipWriter, from: Double = 0, to: Double, audio: AVAudioFormat? = nil,
                               audioFrom: Double? = nil) throws {
        var nextSound = audioFrom ?? from
        for index in 0..<Int(((to - from) * 30).rounded()) {
            let seconds = from + Double(index) / 30
            while let audio, nextSound < seconds {
                if let error = writer.append(sound(at: nextSound, frames: 1024, format: audio), of: .microphone) { throw error }
                nextSound += 1024 / audio.sampleRate
            }
            if let error = writer.append(frame(at: seconds), of: .screen) { throw error }
            usleep(10_000)
        }
    }

    private static func finish(_ writer: ClipWriter, at seconds: Double) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            writer.finish(at: time(seconds)) { continuation.resume(with: $0) }
        }
    }

    @Test(arguments: [(48_000.0, 1 as AVAudioChannelCount), (44_100, 1), (24_000, 1), (48_000, 2)])
    func microphoneBecomesStereoAAC(sampleRate: Double, channels: AVAudioChannelCount) async throws {
        let folder = try TemporaryFolder()
        let writer = try ClipWriter(url: folder.file("clip.mov"), width: 640, height: 360, microphone: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        try Self.record(writer, to: 2, audio: format)
        let url = try #require(try await Self.finish(writer, at: 2))
        let info = try videoInfo(url)
        #expect(info.width == 640 && info.height == 360)
        #expect(info.audioChannels == 2 && info.audioSampleRate == 48000)
    }

    // A clip whose last frames don't change still lasts until Stop, and no longer.
    @Test func clipEndsAtStopAfterAStillScreen() async throws {
        let folder = try TemporaryFolder()
        let writer = try ClipWriter(url: folder.file("clip.mov"), width: 640, height: 360, microphone: false)
        try Self.record(writer, to: 1)
        let url = try #require(try await Self.finish(writer, at: 6))
        let duration = try videoInfo(url).duration
        #expect(abs(duration - 6) < 0.02)
    }

    @Test func soundFromBeforeTheFirstFrameIsDropped() async throws {
        let folder = try TemporaryFolder()
        let writer = try ClipWriter(url: folder.file("clip.mov"), width: 640, height: 360, microphone: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try Self.record(writer, from: 1, to: 3, audio: format, audioFrom: 0)
        let url = try #require(try await Self.finish(writer, at: 3))
        let info = try videoInfo(url)
        #expect(abs(info.duration - 2) < 0.02)
        #expect((info.audioStart ?? 1) < 0.05)
    }

    @Test func clipWithNoFramesIsDeleted() async throws {
        let folder = try TemporaryFolder()
        let file = folder.file("clip.mov")
        let writer = try ClipWriter(url: file, width: 640, height: 360, microphone: false)
        #expect(try await Self.finish(writer, at: 2) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // ScreenCaptureKit marks frames where nothing changed, or the window is hidden; they hold no new picture.
    @Test func incompleteFramesAreSkipped() async throws {
        let folder = try TemporaryFolder()
        let file = folder.file("clip.mov")
        let writer = try ClipWriter(url: file, width: 640, height: 360, microphone: false)
        for (index, status) in [SCFrameStatus.idle, .blank, .suspended, .started].enumerated() {
            #expect(writer.append(Self.frame(at: Double(index) / 30, status: status), of: .screen) == nil)
        }
        #expect(try await Self.finish(writer, at: 1) == nil)
    }

    // Two recordings of the same window, as Screen Stitch writes them, can be joined without re-encoding.
    @Test func recordingsOfTheSameSizeJoin() async throws {
        let folder = try TemporaryFolder()
        var urls: [URL] = []
        for name in ["1.mov", "2.mov"] {
            let writer = try ClipWriter(url: folder.file(name), width: 640, height: 360, microphone: false)
            try Self.record(writer, to: 1)
            urls.append(try #require(try await Self.finish(writer, at: 2)))
        }
        let clips = try urls.map { try Prober.probe($0, ffprobe: tools!.ffprobe) }
        #expect(EncodeJob.canJoin(clips))
        let list = folder.file("list.txt")
        let output = folder.file("joined.mp4")
        var job = EncodeJob(clips: clips, size: .p1080, quality: .standard, output: output)
        job.mode = .join(list: list)
        try job.concatList.write(to: list, atomically: true, encoding: .utf8)
        try run(tools!.ffmpeg, job.arguments.filter { $0 != "pipe:1" && $0 != "-progress" })
        let duration = try videoInfo(output).duration
        #expect(abs(duration - 4) < 0.1, "joined duration \(duration)")
    }

    @Test func discardingDeletesTheFile() throws {
        let folder = try TemporaryFolder()
        let file = folder.file("clip.mov")
        let writer = try ClipWriter(url: file, width: 640, height: 360, microphone: false)
        try Self.record(writer, to: 0.5)
        writer.discard()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

