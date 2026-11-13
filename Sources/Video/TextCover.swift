@preconcurrency import AVFoundation

// Writes a copy of a clip with hidden text covered by solid boxes, for FFmpeg to use in place of the original. Sound is
// copied as it is.
enum TextCover {
    // The box drawn over a track's box, in pixels from the top left. It's padded, since recognition's boxes hug the
    // letters and a sliver of a digit can still be read.
    static func rect(for box: CGRect, width: Double, height: Double) -> CGRect {
        let rect = CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height)
        let pad = max(3, rect.height * 0.35)
        return rect.insetBy(dx: -pad, dy: -pad).integral
    }

    static func write(_ source: URL, covering tracks: [TextTrack], to output: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }, stop: CancelFlag = CancelFlag(),
                      pause: PauseGate = PauseGate()) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let color = (try await video.load(.formatDescriptions).first).flatMap(colorProperties)
        var audioFormats: [CMFormatDescription?] = []
        for track in audio {
            audioFormats.append(try await track.load(.formatDescriptions).first)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try write(asset: asset, video: video, audio: Array(zip(audio, audioFormats)), size: size, transform: transform,
                              color: color, duration: duration, tracks: tracks.map { $0.steadied() }, to: output, progress: progress,
                              stop: stop, pause: pause)
                })
            }
        }
    }

    private static func write(asset: AVURLAsset, video: AVAssetTrack, audio: [(AVAssetTrack, CMFormatDescription?)], size: CGSize,
                              transform: CGAffineTransform, color: [String: String]?, duration: Double, tracks: [TextTrack], to output: URL,
                              progress: @escaping @Sendable (Double) -> Void, stop: CancelFlag, pause: PauseGate) throws {
        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())

        nonisolated(unsafe) let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(videoOutput)
        // A high bit rate, since FFmpeg compresses this copy again. H.264 stops at 4096 pixels across, so larger video
        // uses HEVC.
        var settings: [String: Any] = [
            AVVideoCodecKey: max(width, height) > 4096 ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(width * height * 8, 4_000_000)],
        ]
        if let color {
            settings[AVVideoColorPropertiesKey] = color
        }
        nonisolated(unsafe) let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw TextFinderError.failed("its video format can't be redacted.") }
        writer.add(videoInput)
        nonisolated(unsafe) let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)

        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for (track, format) in audio {
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(readerOutput)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw TextFinderError.failed("its sound format can't be kept in the redacted copy.") }
            writer.add(input)
            pairs.append((readerOutput, input))
        }

        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // Every input is fed on this one queue, so the readers and writers it captures aren't shared between threads.
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "Screen Stitch cover")
        nonisolated(unsafe) var reported = 0.0
        // A frame that can't be covered fails the copy, rather than going into it as it is.
        nonisolated(unsafe) var failure: Error?
        nonisolated(unsafe) var looks: [Int: TextLook] = [:]
        nonisolated(unsafe) let ahead = try LookAhead(asset: asset, video: video, tracks: tracks)
        group.enter()
        videoInput.requestMediaDataWhenReady(on: queue) {
            while videoInput.isReadyForMoreMediaData {
                while pause.isPaused, !stop.isSet {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                guard !stop.isSet, let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                do {
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw CocoaError(.fileReadCorruptFile) }
                    try ahead.read(through: time.seconds + TextTrack.lead)
                    try cover(buffer, at: time.seconds, tracks: tracks, looks: &looks, firstLooks: ahead.looks)
                    if adaptor.append(buffer, withPresentationTime: time) {
                        let done = duration > 0 ? min(time.seconds / duration, 1) : 0
                        if done - reported >= 0.005 {
                            reported = done
                            progress(done)
                        }
                        continue
                    }
                } catch {
                    failure = error
                }
                videoInput.markAsFinished()
                group.leave()
                return
            }
        }
        for pair in pairs {
            nonisolated(unsafe) let (readerOutput, input) = pair
            group.enter()
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard !stop.isSet, let sample = readerOutput.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        group.wait()

        if stop.isSet || failure != nil {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw failure ?? CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        if writer.status != .completed {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    // The clip's colour settings, so the copy matches clips that aren't redacted. Nil when any are missing.
    private static func colorProperties(_ format: CMFormatDescription) -> [String: String]? {
        let keys = [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimariesKey),
                    (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunctionKey),
                    (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrixKey)]
        var properties: [String: String] = [:]
        for (from, to) in keys {
            guard let value = CMFormatDescriptionGetExtension(format, extensionKey: from) as? String else { return nil }
            properties[to] = value
        }
        return properties
    }

    // A box drawn while its text goes unread stays only where the text looks as it did when read (the last reading, or
    // the first for a box drawn early), so boxes don't linger after text scrolls away or show up before it arrives.
    private static func cover(_ buffer: CVPixelBuffer, at time: Double, tracks: [TextTrack], looks: inout [Int: TextLook],
                              firstLooks: [Int: TextLook]) throws {
        let boxes = tracks.indices.compactMap { index in tracks[index].box(at: time).map { (index, $0) } }
        guard !boxes.isEmpty else { return }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw CocoaError(.fileWriteUnknown) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        let frame = TextLook.Frame(base: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), width: width, height: height)
        // Every box is checked against the picture before any is drawn, since boxes can overlap.
        var drawn: [CGRect] = []
        for (index, box) in boxes {
            let rect = rect(for: box, width: Double(width), height: Double(height))
            let track = tracks[index]
            if track.isSighted(at: time) {
                looks[index] = TextLook(frame, rect)
            } else if let look = time > track.sightings[0].time ? looks[index] : firstLooks[index], !look.matches(frame, rect) {
                continue
            }
            drawn.append(rect)
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for rect in drawn {
            // CoreGraphics counts from the bottom.
            context.fill(CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height))
        }
    }
}

// Reads the video a lead ahead of the copy, for how each track's text looks when it's first read, so a box drawn
// early can be checked against it.
final class LookAhead {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var firsts: [(time: Double, track: Int, box: CGRect)]
    private var readTo = -Double.infinity
    private(set) var looks: [Int: TextLook] = [:]

    init(asset: AVAsset, video: AVAssetTrack, tracks: [TextTrack]) throws {
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        firsts = tracks.indices.map { (tracks[$0].sightings[0].time, $0, tracks[$0].sightings[0].box) }.sorted { $0.time < $1.time }
        guard firsts.isEmpty || reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
    }

    func read(through time: Double) throws {
        while readTo < time, let first = firsts.first, first.time <= time {
            guard let sample = output.copyNextSampleBuffer() else {
                firsts.removeAll()
                return
            }
            readTo = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let due = firsts.prefix { $0.time <= readTo + 0.0005 }
            guard !due.isEmpty else { continue }
            firsts.removeFirst(due.count)
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { continue }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { continue }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let frame = TextLook.Frame(base: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), width: width, height: height)
            for first in due where abs(first.time - readTo) < 0.0005 {
                looks[first.track] = TextLook(frame, TextCover.rect(for: first.box, width: Double(width), height: Double(height)))
            }
        }
    }

    deinit {
        reader.cancelReading()
    }
}

// The brightness of the pixels under a box when its text was read.
struct TextLook {
    struct Frame {
        let base: UnsafeMutableRawPointer
        let bytesPerRow: Int
        let width: Int
        let height: Int

        // From BGRA. Nil outside the frame.
        func brightness(_ x: Int, _ y: Int) -> Double? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let pixel = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
            return 0.114 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.299 * Double(pixel[2])
        }
    }

    // How alike the two halves must be, as a correlation. The same text measures about 1, a different line about 0.5 at
    // most.
    static let alike = 0.7
    // How far the text can drift from its box, in pixels.
    static let drift = 2

    let x: Int, y: Int, width: Int, height: Int
    let pixels: [Double]

    init(_ frame: Frame, _ rect: CGRect) {
        x = Int(rect.minX)
        y = Int(rect.minY)
        width = max(1, Int(rect.width))
        height = max(1, Int(rect.height))
        var pixels: [Double] = []
        pixels.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                pixels.append(frame.brightness(x + column, y + row) ?? -1)
            }
        }
        self.pixels = pixels
    }

    // Whether either half still looks the same, at the box's place now, give or take `drift`. Half is enough, so text
    // that something partly hides keeps its box.
    func matches(_ frame: Frame, _ rect: CGRect) -> Bool {
        let originX = Int(rect.minX), originY = Int(rect.minY)
        let halves = [0..<width / 2, width / 2..<width]
        for dy in -Self.drift...Self.drift {
            for dx in -Self.drift...Self.drift {
                for columns in halves where !columns.isEmpty {
                    if correlation(frame, columns, originX + dx, originY + dy) >= Self.alike { return true }
                }
            }
        }
        return false
    }

    private func correlation(_ frame: Frame, _ columns: Range<Int>, _ originX: Int, _ originY: Int) -> Double {
        var n = 0.0, sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
        for row in 0..<height {
            for column in columns {
                let a = pixels[row * width + column]
                guard a >= 0, let b = frame.brightness(originX + column, originY + row) else { continue }
                n += 1
                sumA += a
                sumB += b
                sumAA += a * a
                sumBB += b * b
                sumAB += a * b
            }
        }
        let varianceA = sumAA - sumA * sumA / max(n, 1), varianceB = sumBB - sumB * sumB / max(n, 1)
        // A blank stretch has nothing left to hide.
        guard n > 0, varianceA > n, varianceB > n else { return 0 }
        return (sumAB - sumA * sumB / n) / (varianceA * varianceB).squareRoot()
    }
}

// Holds a copy between frames while a recording needs the Mac's video encoder.
final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    var isPaused: Bool { lock.withLock { paused } }

    func set(_ on: Bool) {
        lock.withLock { paused = on }
    }
}
