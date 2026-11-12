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
                      progress: @escaping @Sendable (Double) -> Void = { _ in }, stop: CancelFlag = CancelFlag()) async throws {
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
                              stop: stop)
                })
            }
        }
    }

    private static func write(asset: AVURLAsset, video: AVAssetTrack, audio: [(AVAssetTrack, CMFormatDescription?)], size: CGSize,
                              transform: CGAffineTransform, color: [String: String]?, duration: Double, tracks: [TextTrack], to output: URL,
                              progress: @escaping @Sendable (Double) -> Void, stop: CancelFlag) throws {
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
        group.enter()
        videoInput.requestMediaDataWhenReady(on: queue) {
            while videoInput.isReadyForMoreMediaData {
                guard !stop.isSet, let sample = videoOutput.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                cover(buffer, boxes: tracks.compactMap { $0.box(at: time.seconds) })
                if !adaptor.append(buffer, withPresentationTime: time) {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                let done = duration > 0 ? min(time.seconds / duration, 1) : 0
                if done - reported >= 0.005 {
                    reported = done
                    progress(done)
                }
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

        if stop.isSet {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
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

    private static func cover(_ buffer: CVPixelBuffer, boxes: [CGRect]) {
        guard !boxes.isEmpty else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for box in boxes {
            let rect = rect(for: box, width: Double(width), height: Double(height))
            // CoreGraphics counts from the bottom.
            context.fill(CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height))
        }
    }
}
