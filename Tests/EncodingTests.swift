import Foundation
import Testing

@Suite struct CanvasTests {
    @Test func smallClipKeepsItsSize() {
        let canvas = EncodeJob.canvas(for: [makeClip(width: 1280, height: 720)], size: .p1080)
        #expect(canvas.width == 1280 && canvas.height == 720 && canvas.scale == 1)
    }

    // The example in the README.
    @Test func retinaRecordingAt1080p() {
        let canvas = EncodeJob.canvas(for: [makeClip(width: 3456, height: 2234)], size: .p1080)
        #expect(canvas.width == 1670 && canvas.height == 1080)
    }

    @Test func originalNeverScales() {
        let canvas = EncodeJob.canvas(for: [makeClip(width: 3456, height: 2234)], size: .original)
        #expect(canvas.width == 3456 && canvas.height == 2234 && canvas.scale == 1)
    }

    @Test func capAppliesToTheShortSideOfPortraitVideo() {
        let canvas = EncodeJob.canvas(for: [makeClip(width: 1080, height: 1920)], size: .p720)
        #expect(canvas.width == 720 && canvas.height == 1280)
    }

    @Test func mismatchedClipsShareTheBoundingBox() {
        let clips = [makeClip(width: 1600, height: 900), makeClip(width: 1000, height: 1200)]
        let canvas = EncodeJob.canvas(for: clips, size: .original)
        #expect(canvas.width == 1600 && canvas.height == 1200 && canvas.scale == 1)
    }

    @Test func boundingBoxIsCappedAsAWhole() {
        let clips = [makeClip(width: 1834, height: 1680), makeClip(width: 1264, height: 1440)]
        let canvas = EncodeJob.canvas(for: clips, size: .p1080)
        #expect(canvas.height == 1080)
        #expect(canvas.width == 1180)
        #expect(abs(canvas.scale - 1080.0 / 1680) < 1e-9)
    }

    @Test func dimensionsAreEven() {
        let canvas = EncodeJob.canvas(for: [makeClip(width: 1001, height: 601)], size: .original)
        #expect(canvas.width % 2 == 0 && canvas.height % 2 == 0)
    }

    @Test func noClips() {
        let canvas = EncodeJob.canvas(for: [], size: .p1080)
        #expect(canvas.width == 0 && canvas.height == 0)
    }
}

@Suite struct ArgumentTests {
    private func filterGraph(_ job: EncodeJob) -> String {
        let arguments = job.arguments
        return arguments[arguments.firstIndex(of: "-filter_complex")! + 1]
    }

    private func job(_ clips: [Clip], size: OutputSize = .original, quality: Quality = .standard) -> EncodeJob {
        EncodeJob(clips: clips, size: size, quality: quality, output: URL(fileURLWithPath: "/tmp/out.mp4"))
    }

    @Test func silentClipsMakeSilentVideo() {
        let silent = job([makeClip(), makeClip()])
        #expect(filterGraph(silent).hasSuffix("concat=n=2:v=1:a=0[v]"))
        #expect(!silent.arguments.contains("[a]"))
        #expect(!silent.arguments.contains("-c:a"))
    }

    @Test func clipsWithoutAudioGetSilenceWhenOthersHaveIt() {
        let mixed = job([makeClip("a.mov", duration: 2.5, audioStreams: 1), makeClip("b.mov", duration: 4)])
        #expect(mixed.arguments.contains("anullsrc=r=48000:cl=stereo"))
        #expect(mixed.arguments.contains("4.000"))
        #expect(filterGraph(mixed).hasSuffix("concat=n=2:v=1:a=1[v][a]"))
        #expect(mixed.arguments.contains("[a]"))
    }

    @Test func severalAudioTracksAreMixed() {
        #expect(filterGraph(job([makeClip(audioStreams: 3)])).contains("amix=inputs=3"))
    }

    @Test func usesTheClipsVideoStream() {
        #expect(filterGraph(job([makeClip(videoStream: 2)])).hasPrefix("[0:v:2]"))
    }

    @Test func smallerClipsAreCenteredNotEnlarged() {
        let graph = filterGraph(job([makeClip(width: 1600, height: 900), makeClip(width: 800, height: 600)]))
        #expect(graph.contains("scale=w='min(1600,iw*1.0)':h='min(900,ih*1.0)'"))
        #expect(graph.contains("pad=1600:900:(ow-iw)/2:(oh-ih)/2"))
    }

    @Test(arguments: [(Quality.high, "20"), (.standard, "23"), (.small, "28")])
    func qualitySetsCRF(quality: Quality, crf: String) {
        let arguments = job([makeClip()], quality: quality).arguments
        #expect(arguments[arguments.firstIndex(of: "-crf")! + 1] == crf)
    }

    @Test func outputComesLast() {
        #expect(job([makeClip()]).arguments.last == "/tmp/out.mp4")
    }
}

@Suite struct SettingParsingTests {
    @Test(arguments: [("original", OutputSize.original), ("ORIGINAL", .original), ("1440", .p1440), ("1080p", .p1080),
                      ("720", .p720)])
    func sizes(argument: String, size: OutputSize) {
        #expect(OutputSize(argument: argument) == size)
    }

    @Test(arguments: ["999", "4k", "", "p"])
    func unknownSizes(argument: String) {
        #expect(OutputSize(argument: argument) == nil)
    }

    @Test(arguments: [("high", Quality.high), ("Standard", .standard), ("small", .small)])
    func qualities(argument: String, quality: Quality) {
        #expect(Quality(argument: argument) == quality)
    }

    @Test func unknownQuality() {
        #expect(Quality(argument: "smaller file") == nil)
    }
}

@Suite struct JoinTests {
    private func clip(_ name: String, format: String?) -> Clip {
        var clip = makeClip(name)
        clip.copyFormat = format
        return clip
    }

    @Test func sameFormatCanBeJoined() {
        #expect(EncodeJob.canJoin([clip("a.mov", format: "video:h264:x"), clip("b.mov", format: "video:h264:x")]))
    }

    @Test func differentFormatsCantBeJoined() {
        #expect(!EncodeJob.canJoin([clip("a.mov", format: "video:h264:x"), clip("b.mov", format: "video:h264:y")]))
    }

    @Test func clipsThatCantBeCopiedCantBeJoined() {
        #expect(!EncodeJob.canJoin([clip("a.mov", format: nil), clip("b.mov", format: nil)]))
    }

    @Test func oneClipIsntAJoin() {
        #expect(!EncodeJob.canJoin([clip("a.mov", format: "video:h264:x")]))
    }

    @Test func listQuotesPaths() {
        let job = EncodeJob(clips: [makeClip("Chris's clip.mov"), makeClip("b.mov")], size: .p1080, quality: .standard,
                            output: URL(fileURLWithPath: "/tmp/out.mp4"))
        #expect(job.concatList == "file '/tmp/Chris'\\''s clip.mov'\nfile '/tmp/b.mov'\n")
    }

    @Test func joiningCopiesInsteadOfEncoding() {
        var job = EncodeJob(clips: [clip("a.mov", format: "video:hevc:x"), clip("b.mov", format: "video:hevc:x")],
                            size: .p1080, quality: .standard, output: URL(fileURLWithPath: "/tmp/out.mp4"))
        job.mode = .join(list: URL(fileURLWithPath: "/tmp/list.txt"))
        let arguments = job.arguments
        #expect(arguments.contains("concat"))
        #expect(arguments[arguments.firstIndex(of: "-c")! + 1] == "copy")
        #expect(!arguments.contains("libx264"))
        #expect(arguments[arguments.firstIndex(of: "-tag:v")! + 1] == "hvc1")
        #expect(arguments.last == "/tmp/out.mp4")
    }
}
