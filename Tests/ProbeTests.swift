import Foundation
import Testing

@Suite(.enabled(if: tools != nil, "needs FFmpeg"))
struct ProbeTests {
    private func probe(_ url: URL) throws -> Clip {
        try Prober.probe(url, ffprobe: tools!.ffprobe)
    }

    @Test func readsSizeDurationAndAudio() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("clip.mov")
        try makeVideo(url, width: 320, height: 240, seconds: 2, audio: true)
        let clip = try probe(url)
        #expect(clip.width == 320 && clip.height == 240)
        #expect(abs(clip.duration - 2) < 0.1)
        #expect(clip.audioStreams == 1)
        #expect(clip.fileSize > 0)
    }

    @Test func countsEveryAudioTrack() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("clip.mov")
        try makeVideo(url, width: 320, height: 240, audio: true, options: ["-map", "0:v", "-map", "1:a", "-map", "1:a"])
        #expect(try probe(url).audioStreams == 2)
    }

    // Phone videos are often stored sideways with a rotation flag.
    @Test func rotatedVideoReportsItsShownSize() throws {
        let folder = try TemporaryFolder()
        let stored = folder.file("stored.mov")
        let rotated = folder.file("rotated.mov")
        try makeVideo(stored, width: 320, height: 240)
        try run(tools!.ffmpeg, ["-v", "error", "-y", "-display_rotation", "90", "-i", stored.path, "-c", "copy", rotated.path])
        let clip = try probe(rotated)
        #expect(clip.width == 240 && clip.height == 320)
    }

    @Test func usesTheRecordingTimeTag() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("clip.mov")
        try makeVideo(url, width: 320, height: 240, options: ["-metadata", "creation_time=2024-01-02T03:04:05Z"])
        #expect(try probe(url).date == ISO8601DateFormatter().date(from: "2024-01-02T03:04:05Z"))
    }

    // The macOS screenshot toolbar writes this tag with the local time zone.
    @Test func prefersTheQuickTimeCreationDate() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("clip.mov")
        try makeVideo(url, width: 320, height: 240, options: [
            "-metadata", "creation_time=2024-01-02T03:04:05Z",
            "-metadata", "com.apple.quicktime.creationdate=2024-05-06T07:08:09-0500",
            "-movflags", "use_metadata_tags",
        ])
        #expect(try probe(url).date == ISO8601DateFormatter().date(from: "2024-05-06T12:08:09Z"))
    }

    @Test func sameSettingsGiveTheSameCopyFormat() throws {
        let folder = try TemporaryFolder()
        let first = folder.file("1.mov")
        let second = folder.file("2.mov")
        let bigger = folder.file("3.mov")
        try makeVideo(first, width: 320, height: 240, audio: true)
        try makeVideo(second, width: 320, height: 240, color: "white", audio: true)
        try makeVideo(bigger, width: 640, height: 480, audio: true)
        let format = try #require(try probe(first).copyFormat)
        #expect(try probe(second).copyFormat == format)
        #expect(try probe(bigger).copyFormat != format)
    }

    // MP4 can't hold PCM audio as is, so such a clip can only be combined by compressing.
    @Test func uncommonAudioCantBeCopied() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("clip.mov")
        try run(tools!.ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=orange:s=320x240:d=1:r=30", "-f", "lavfi",
                                "-i", "sine=duration=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", url.path])
        #expect(try probe(url).copyFormat == nil)
    }

    @Test func audioOnlyFileIsRejected() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("sound.m4a")
        try run(tools!.ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=duration=1", url.path])
        #expect(throws: ProbeError.self) { try probe(url) }
    }

    @Test func nonVideoIsRejected() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("notes.mov")
        try Data("not a video".utf8).write(to: url)
        #expect(throws: ProbeError.self) { try probe(url) }
    }
}
