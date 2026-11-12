import AppKit
@preconcurrency import AVFoundation
import Testing
import Vision

@Suite struct TextTrackTests {
    private func track(_ points: [(Double, Double)]) -> TextTrack {
        TextTrack(text: "4242", sightings: points.map { .init(time: $0.0, box: CGRect(x: 0.1, y: $0.1, width: 0.1, height: 0.05)) })
    }

    // From camp.mp4: the quick reading boxes "9611" at 25×9 pixels, the careful one every half second at 32×16 and a
    // couple of pixels over.
    @Test func stillTextGetsOneBoxThatStaysOnItsLine() {
        let quick = CGRect(x: 619 / 1728.0, y: 745 / 1080.0, width: 25 / 1728.0, height: 9 / 1080.0)
        let careful = CGRect(x: 618 / 1728.0, y: 743 / 1080.0, width: 32 / 1728.0, height: 16 / 1080.0)
        let readings = (0..<60).map { TextTrack.Sighting(time: Double($0) / 30, box: $0 % 15 == 0 ? careful : quick) }
        let steady = TextTrack(text: "9611", sightings: readings).steadied()
        let boxes = Set(stride(from: 0.0, through: 2, by: 0.01).compactMap { steady.box(at: $0) })
        #expect(boxes.count == 1)
        let box = boxes.first!.insetBy(dx: -1e-9, dy: -1e-9)
        #expect(box.contains(quick))
        #expect(box.minX <= careful.minX && box.maxX >= careful.maxX)
        // The careful reading's box takes in the gap between lines, so it doesn't set the height.
        #expect(abs(boxes.first!.height - quick.height) < 1e-9)
    }

    @Test func scrollingTextKeepsOneSize() {
        let readings = (0..<60).map { frame in
            let height = frame % 15 == 0 ? 0.015 : 0.009
            return TextTrack.Sighting(time: Double(frame) / 30, box: CGRect(x: 0.36, y: 0.7 - Double(frame) * 0.004, width: 0.015, height: height))
        }
        let steady = TextTrack(text: "9611", sightings: readings).steadied()
        let boxes = stride(from: 0.0, through: 1.9, by: 0.01).compactMap { steady.box(at: $0) }
        #expect(Set(boxes.map(\.height)).count == 1)
        #expect(boxes.first!.minY > boxes.last!.minY)
    }

    @Test func textThatJumpsIsntStretchedOver() {
        let steady = TextTrack(text: "9611", sightings: [
            .init(time: 0, box: CGRect(x: 0.3, y: 0.6, width: 0.02, height: 0.01)),
            .init(time: 0.5, box: CGRect(x: 0.3, y: 0.6, width: 0.02, height: 0.01)),
            .init(time: 0.6, box: CGRect(x: 0.3, y: 0.3, width: 0.02, height: 0.01)),
        ]).steadied()
        #expect(steady.box(at: 0.25)!.maxY < 0.62)
        #expect(steady.box(at: 0.6)!.minY < 0.31)
    }

    @Test func boxesFollowTheTextBetweenSightings() {
        let scrolling = track([(1, 0.8), (2, 0.6)])
        #expect(abs(scrolling.box(at: 1.5)!.minY - 0.7) < 0.0001)
    }

    // As when a window resizes: two readings a frame apart can't tell how the text is moving, so the box holds still.
    @Test func boxesDontFlyOffOnAMomentaryMove() {
        let track = TextTrack(text: "9611", sightings: [.init(time: 4.558, box: CGRect(x: 0.285, y: 0.601, width: 0.02, height: 0.02)),
                                                        .init(time: 4.575, box: CGRect(x: 0.258, y: 0.595, width: 0.02, height: 0.02))])
        #expect(track.box(at: 4.1)?.minX == 0.285)
        #expect(track.box(at: 5.0)?.minX == 0.258)
    }

    @Test func boxesStartEarlyAndEndLateMovingAsTheTextDid() {
        let scrolling = track([(1, 0.8), (2, 0.6)])
        #expect(abs(scrolling.box(at: 0.5)!.minY - 0.9) < 0.0001)
        #expect(abs(scrolling.box(at: 2.5)!.minY - 0.5) < 0.0001)
        #expect(scrolling.box(at: 0.4) == nil)
        #expect(scrolling.box(at: 2.6) == nil)
        let still = track([(3, 0.4)])
        #expect(still.box(at: 2.6)?.minY == 0.4)
    }
}

@Suite struct TextTrackerTests {
    // Each frame's time and the top of each box found in it.
    private func frames(_ readings: [(Double, [Double])]) -> [TextTracker.Frame] {
        readings.map { time, found in
            TextTracker.Frame(time: time, found: found.map { TextTracker.Found(text: "4242", box: CGRect(x: 0.1, y: $0, width: 0.1, height: 0.05)) })
        }
    }

    @Test func aShortGapKeepsOneTrack() {
        let tracks = TextTracker.tracks(for: "4242", in: frames([(0, [0.5]), (0.1, []), (0.2, [0.5])]))
        #expect(tracks.count == 1)
        #expect(tracks[0].sightings.map(\.time) == [0, 0.2])
    }

    @Test func aLongGapStartsANewTrack() {
        let tracks = TextTracker.tracks(for: "4242", in: frames([(0, [0.5]), (0.6, []), (1.2, []), (1.5, [0.5])]))
        #expect(tracks.count == 2)
    }

    // A screen recording adds no frames while nothing changes, so a pause between frames isn't the text going missing.
    @Test func aPauseWithoutFramesKeepsOneTrack() {
        let tracks = TextTracker.tracks(for: "4242", in: frames([(0, [0.5]), (3, [0.5])]))
        #expect(tracks.count == 1)
    }

    @Test func trackingFollowsAScroll() {
        let tracks = TextTracker.tracks(for: "4242", in: frames([(0, [0.8]), (0.1, [0.77]), (0.2, [0.74]), (0.4, [0.68])]))
        #expect(tracks.count == 1)
    }

    // When a new message pushes the chat up, the old box stops where the text was once it shows up in its new place, and
    // the new box starts only just before, enough to cover the text fading in.
    @Test func aBoxDoesntLingerWhereTheTextJumpedFrom() {
        let tracks = TextTracker.covering(TextTracker.tracks(for: "4242", in: frames([
            (2.0, [0.574]), (2.2, [0.574]), (2.34, [0.574]), (2.37, [0.416]), (2.5, [0.416]),
        ])))
        #expect(tracks.count == 2)
        #expect(abs(tracks[0].end - 2.37) < 0.0001)
        #expect(abs(tracks[1].start - (2.37 - TextTrack.jumpLead)) < 0.0001)
        #expect(tracks[0].box(at: 2.6) == nil)
    }

    // As when something sits over the text for a few seconds: the box stays through the gap.
    @Test func textThatPicksUpInTheSamePlaceIsCoveredThroughTheGap() {
        var readings: [(Double, [Double])] = [(0, [0.5]), (0.5, [0.5])]
        readings += (2...7).map { (Double($0) * 0.5, []) }
        readings.append((4, [0.5]))
        let tracks = TextTracker.covering(TextTracker.tracks(for: "4242", in: frames(readings)))
        #expect(tracks.count == 1)
        #expect(tracks[0].box(at: 2.5)?.minY == 0.5)
    }

    @Test func readingsAreMergedWithoutCountingAPlaceTwice() {
        let a = TextTracker.Found(text: "4242", box: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05))
        let nearlyA = TextTracker.Found(text: "4242", box: CGRect(x: 0.101, y: 0.1, width: 0.1, height: 0.05))
        let b = TextTracker.Found(text: "4242", box: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05))
        #expect(TextTracker.merge([a], [nearlyA, b]) == [a, b])
    }

    @Test func eachPlaceGetsItsOwnTrack() {
        let tracks = TextTracker.tracks(for: "4242", in: frames([(0, [0.5]), (0.1, [0.5, 0.1])]))
        #expect(tracks.map(\.sightings.count) == [2, 1])
    }

    @Test func framesInGapsAndAroundTracksAreReadAgain() {
        let all = frames([(0, []), (0.3, [0.5]), (0.4, []), (0.5, [0.5]), (1.5, []), (2.0, [])])
        let tracks = TextTracker.tracks(for: "4242", in: all)
        #expect(TextTracker.timesToRecheck(tracks, in: all) == [0, 0.4])
    }

    // The quick pass can lose text for a few seconds while something passes over it.
    @Test func shortGapsBetweenTracksAreReadAgain() {
        var readings: [(Double, [Double])] = [(0, [0.5])]
        readings += (1...8).map { (Double($0) * 0.5, []) }
        readings.append((4.5, [0.5]))
        readings += (10...20).map { (Double($0) * 0.5, []) }
        readings.append((10.5, [0.5]))
        let all = frames(readings)
        let tracks = TextTracker.tracks(for: "4242", in: all)
        #expect(tracks.count == 3)
        let recheck = TextTracker.timesToRecheck(tracks, in: all)
        #expect([1.0, 2.0, 3.5].allSatisfy { recheck.contains($0) })
        #expect(![6.5, 7.5, 8.5].contains { recheck.contains($0) })
    }

    @Test func matchesIgnoreCaseAndCatchReadingsOneCharacterOff() {
        let line = "card ending 9611 and 611, then 96111 and ABCD"
        let found = TextFinder.matches(of: "9611", in: line)
        #expect(found.map { String(line[$0.0]) } == ["9611", "9611", "611"])
        #expect(found.map(\.missing) == [0, 0, 1])
        #expect(TextFinder.matches(of: "abcd", in: line).map { String(line[$0.0]) } == ["ABCD"])
        // Look-alike characters count as the same.
        #expect(TextFinder.matches(of: "9611", in: "ending 96ll and 96I1").map { String("ending 96ll and 96I1"[$0.0]) } == ["96ll", "96I1"])
        // Short text could match too much by being one character off.
        #expect(TextFinder.matches(of: "and", in: "end and").count == 1)
    }
}

@Suite struct TextFinderTests {
    @Test func runsOfTimesStayTogetherWhenSplitBetweenWorkers() {
        let groups = TextFinder.split([1, 1.1, 1.2, 5, 9, 9.5], into: 3)
        #expect(groups == [[1, 1.1, 1.2], [5, 9, 9.5]])
    }

    @Test func boxesArePaddedSoNoSliverOfALetterShows() {
        let rect = TextCover.rect(for: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.02), width: 1000, height: 1000)
        #expect(rect.minX <= 493 && rect.maxX >= 607 && rect.minY <= 493 && rect.maxY >= 527)
    }

    // A file with no video isn't counted as searched with nothing found, which would let it through unredacted.
    @Test func aFileWithoutVideoFailsInsteadOfFindingNothing() async throws {
        let folder = try TemporaryFolder()
        let sound = folder.file("sound.m4a")
        try run(tools!.ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", sound.path])
        await #expect(throws: TextFinderError.self) { try await TextFinder.find(["9611"], in: sound) }
    }
}

@MainActor
@Suite struct HidingTextTests {
    @Test func hiddenTextIsCoveredEverywhereItScrollsAndTheRestStaysReadable() async throws {
        let folder = try TemporaryFolder()
        let video = folder.file("chat.mov")
        try await makeScrollingChat(video)

        let found = try await TextFinder.find(["4242"], in: video)
        let tracks = try #require(found["4242"])
        #expect(!tracks.isEmpty)

        let covered = folder.file("covered.mov")
        try await TextCover.write(video, covering: tracks, to: covered)
        let original = try readText(video)
        let after = try readText(covered)
        #expect(original.contains { $0.contains("4242") })
        #expect(!after.contains { $0.contains("4242") || $0.contains("424") })
        #expect(after.contains { $0.contains("Order total") })
    }

    // Waits for the background search to look through every clip.
    private func searched(_ model: StitchModel) async throws {
        for _ in 0..<600 where model.clips.contains(where: model.needsSearch) || model.searchingClip != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func combiningWithoutCompressingWaitsUntilTheTextIsKnownNotToBeThere() async throws {
        let folder = try TemporaryFolder()
        let model = StitchModel()
        for name in ["1.mp4", "2.mp4"] {
            try makeVideo(folder.file(name), width: 320, height: 240)
            model.items.append(.clip(try Prober.probe(folder.file(name), ffprobe: tools!.ffprobe)))
        }
        #expect(model.canCombineWithoutCompressing)
        model.addHiddenText("9611")
        #expect(!model.canCombineWithoutCompressing)
        try await searched(model)
        #expect(model.canCombineWithoutCompressing)
        #expect(model.hidingLine == "Redacting 9611 · Not found in these clips")
        #expect(model.hiddenTextStatus(model.hiddenText[0]) == "Not found in these clips")
    }

    @Test func combiningCoversHiddenTextAndRecordsWhereInTheVideo() async throws {
        let folder = try TemporaryFolder()
        let video = folder.file("chat.mov")
        try await makeScrollingChat(video)
        let model = StitchModel()
        model.addTitleCard()
        model.items.append(.clip(try Prober.probe(video, ffprobe: tools!.ffprobe)))
        model.addHiddenText("4242")
        try await searched(model)
        #expect(model.hiddenTextStatus(model.hiddenText[0])?.hasPrefix("Found in") == true)
        #expect(!model.hiddenPlaces(in: model.clips[0]).isEmpty)

        // The app shares this folder, so only copies made during the test count.
        let covered = {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix("screen-stitch-covered-") })
        }
        let before = try covered()
        let output = folder.file("out.mp4")
        model.encode(to: output)
        while model.isEncoding {
            try await Task.sleep(for: .milliseconds(100))
        }
        if case let .failed(message) = model.state { Issue.record("\(message)") }
        let text = try readText(output)
        #expect(!text.contains { $0.contains("4242") })
        #expect(text.contains { $0.contains("Order total") })
        // The places are in the saved video's time, after the title card.
        let record = try #require(model.hiddenRecord(for: output))
        #expect(record.texts == ["4242"])
        #expect(record.places.map(\.clip) == [1])
        #expect(record.places[0].start >= model.titleCards[0].duration)
        #expect(model.hiddenSummary(for: output) == "4242 redacted in 1 place. Check it before you share.")
        #expect(model.staleNote(for: output) == nil)
        model.addHiddenText("Order total")
        #expect(model.staleNote(for: output) == "This video doesn't redact “Order total”. Combine again to redact it.")
        // The covered copy is gone once the video is made.
        #expect(try covered().subtracting(before).isEmpty)
    }

    @Test func theSummaryOnlyCallsFoundTextHidden() {
        let model = StitchModel()
        let video = URL(fileURLWithPath: "/tmp/out.mp4")
        let place = HiddenPlace(start: 1, end: 2, text: "9611", clip: 1)
        model.hiddenRecords[video] = HiddenRecord(texts: ["9611", "9820"], places: [place, place])
        #expect(model.hiddenSummary(for: video) == "9611 redacted in 2 places. 9820 wasn't found. Check them before you share.")
        model.hiddenRecords[video] = HiddenRecord(texts: ["9611", "9820"], places: [])
        #expect(model.hiddenSummary(for: video) == "Nothing was redacted. 9611 and 9820 weren't found.")
    }

    @Test func eachLineIsItsOwnEntryAndShortOnesAreRefused() {
        let model = StitchModel()
        #expect(model.addHiddenText("ab") == "Type at least 3 characters.")
        #expect(model.addHiddenText("9611\n 9820 \nab\n") == nil)
        #expect(model.hiddenText.map(\.text) == ["9611", "9820"])
        model.setHiddenText("9611", isOn: false)
        #expect(model.activeHiddenText == ["9820"])
        // Adding text that's already there checks it again instead of adding it twice.
        model.addHiddenText("9611")
        #expect(model.hiddenText.map(\.isOn) == [true, true])
        #expect(model.hidingLine == "Redacting 9611 and 9820")
        model.removeHiddenText("9820")
        #expect(model.activeHiddenText == ["9611"])
    }

    @Test func recordsAreSavedWithTheSession() async throws {
        let folder = try TemporaryFolder()
        let video = folder.file("clip.mov")
        try makeVideo(video, width: 320, height: 240)
        let output = folder.file("out.mp4")
        try Data().write(to: output)
        let file = folder.file("session.json")
        let record = HiddenRecord(texts: ["9611"], places: [HiddenPlace(start: 1, end: 2, text: "9611", clip: 1)])
        try SavedSession(items: [.clip(video)], isManuallyOrdered: false, recordings: [], outputs: [output],
                         hiddenRecords: [output.path: record]).save(to: file)

        let model = StitchModel()
        model.sessionFile = file
        await model.restoreSession()?.value
        #expect(model.hiddenRecord(for: output) == record)
        model.saveSession()
        #expect(SavedSession.load(from: file)?.hiddenRecords == [output.path: record])
    }

    // What a search found is kept for the file as it is. A file changed since, even at the same path, is searched again.
    @Test func foundPlacesAreKeptUntilTheFileChanges() async throws {
        let folder = try TemporaryFolder()
        let cache = folder.file("cache")
        let video = folder.file("clip.mov")
        try makeVideo(video, width: 320, height: 240)
        let search = TextSearch(url: video, cacheFolder: cache)
        search.look(for: ["9611"])
        await search.finished()
        #expect(search.found["9611"] == [])
        #expect(TextSearch(url: video, cacheFolder: cache).found["9611"] == [])

        try makeVideo(video, width: 320, height: 240, seconds: 2)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: video.path)
        #expect(TextSearch(url: video, cacheFolder: cache).found["9611"] == nil)
        search.checkFile()
        #expect(search.found["9611"] == nil)
    }

    // The row's spinner is drawn from `isBusy`, so it has to be told when the search ends.
    @Test func viewsAreToldWhenASearchEnds() async throws {
        let folder = try TemporaryFolder()
        let video = folder.file("clip.mov")
        try makeVideo(video, width: 320, height: 240)
        let search = TextSearch(url: video, cacheFolder: nil)
        search.look(for: ["9611"])
        #expect(search.isBusy)
        final class Flag: @unchecked Sendable { var isSet = false }
        let told = Flag()
        withObservationTracking { _ = search.isBusy } onChange: { told.isSet = true }
        await search.finished()
        #expect(!search.isBusy)
        #expect(told.isSet)
    }

    @Test func aClipThatCouldntBeSearchedSaysSo() async throws {
        let folder = try TemporaryFolder()
        let sound = folder.file("sound.m4a")
        try run(tools!.ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", sound.path])
        let model = StitchModel()
        model.items = [.clip(Clip(url: sound, date: Date(), duration: 1, width: 320, height: 240, videoStream: 0, audioStreams: 1,
                                  fileSize: 0))]
        model.addHiddenText("9611")
        try await searched(model)
        #expect(model.hiddenTextStatus(model.hiddenText[0]) == "Couldn't search “sound.m4a”")
        #expect(model.hidingLine == "Redacting 9611 · Couldn't search “sound.m4a”")
        #expect(!model.canCombineWithoutCompressing)
    }

    @Test func placesRunTogetherWhenCloseAndStayWithinTheClip() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05)
        let tracks = [
            TextTrack(text: "a", sightings: [.init(time: 0.2, box: box), .init(time: 2, box: box)]),
            TextTrack(text: "a", sightings: [.init(time: 2.8, box: box)]),
            TextTrack(text: "a", sightings: [.init(time: 6, box: box), .init(time: 9.9, box: box)]),
        ]
        #expect(StitchModel.places(of: tracks, duration: 10) == [0...3.3, 5.5...10])
    }
}

// A light chat window, 3 seconds long, where "card ending 4242" scrolls up from the bottom past the top edge while
// "Order total" stays put.
private func makeScrollingChat(_ url: URL) async throws {
    let width = 1280, height = 720, fps = 20, frames = 60
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let font = NSFont.systemFont(ofSize: 28)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor(white: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        NSAttributedString(string: "Order total $36.00", attributes: attributes).draw(at: NSPoint(x: 80, y: 600))
        // From below the bottom edge to above the top one, counted from the bottom.
        let y = -40 + Double(frame) / Double(frames - 1) * Double(height + 60)
        NSAttributedString(string: "Booked on the card ending 4242 today", attributes: attributes).draw(at: NSPoint(x: 420, y: y))
        NSGraphicsContext.restoreGraphicsState()
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

// Every line read in every frame, carefully.
private func readText(_ url: URL) throws -> [String] {
    let asset = AVURLAsset(url: url)
    let reader = try AVAssetReader(asset: asset)
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var track: AVAssetTrack?
    asset.loadTracks(withMediaType: .video) { tracks, _ in
        track = tracks?.first
        semaphore.signal()
    }
    semaphore.wait()
    let output = AVAssetReaderTrackOutput(track: track!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    var lines: [String] = []
    while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        lines += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
    return lines
}

@Suite struct FrameLookTests {
    // A 64×36 grey frame, with any pixels changed by `change`.
    private func frame(grey: UInt8 = 200, change: [(Int, Int, Int)] = []) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        memset(base, Int32(grey), row * 36)
        for (x, y, delta) in change {
            base[y * row + x * 4 + 1] = UInt8(Int(grey) + delta)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    @Test func compressionNoiseLooksTheSame() {
        let read = FrameLook(frame())
        #expect(FrameLook(frame(change: [(3, 4, 12), (40, 20, -16)])).looksLike(read))
    }

    @Test func oneVisibleChangeIsEnough() {
        let read = FrameLook(frame())
        #expect(!FrameLook(frame(change: [(63, 35, 17)])).looksLike(read))
    }

    // Each step of a fade is small, but frames are compared with the one that was read, so the change adds up.
    @Test func aSlowFadeIsntMissed() {
        let read = FrameLook(frame(grey: 200))
        #expect(FrameLook(frame(grey: 190)).looksLike(read))
        #expect(!FrameLook(frame(grey: 180)).looksLike(read))
    }
}
