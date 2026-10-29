import AVFoundation
import ScreenCaptureKit

// Writes a recording's frames and microphone audio to a .mov. ScreenCaptureKit's own SCRecordingOutput ends its file
// whenever the stream's configuration changes, which recentering a resized window needs. Used only on the frames queue.
final class ClipWriter {
    private let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private var lastFrame: CMSampleBuffer?

    init(url: URL, width: Int, height: Int, microphone: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if microphone {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            self.audio = audio
        } else {
            audio = nil
        }
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    // Returns the writer's error once it fails. ScreenCaptureKit sends frames without an image while nothing changes;
    // those are skipped, so a still screen costs almost nothing. Sound from before the first frame is dropped.
    func append(_ buffer: CMSampleBuffer, of type: SCStreamOutputType) -> Error? {
        guard writer.status == .writing else { return writer.error }
        switch type {
        case .screen:
            guard buffer.imageBuffer != nil, Self.status(of: buffer) == .complete else { return nil }
            if lastFrame == nil {
                writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            }
            lastFrame = buffer
            if video.isReadyForMoreMediaData {
                video.append(buffer)
            }
        case .microphone:
            if lastFrame != nil, let audio, audio.isReadyForMoreMediaData {
                audio.append(buffer)
            }
        default:
            break
        }
        return writer.status == .failed ? writer.error : nil
    }

    // Repeats the last frame at `time` and ends the clip there, so it lasts until Stop even if the screen was still at
    // the end. A clip with no frames is deleted and reports nil.
    func finish(at time: CMTime, completion: @escaping (Result<URL?, Error>) -> Void) {
        guard writer.status == .writing, let lastFrame else {
            let error = writer.error
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: url)
            completion(error.map { .failure($0) } ?? .success(nil))
            return
        }
        if time > lastFrame.presentationTimeStamp {
            // Without this frame the clip ends at the last change, so wait up to a second if the encoder is busy.
            var waits = 0
            while !video.isReadyForMoreMediaData, waits < 100 {
                usleep(10_000)
                waits += 1
            }
            // A short duration of its own; left unset, it inherits the still stretch before it, which a join would play.
            let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 600), presentationTimeStamp: time, decodeTimeStamp: .invalid)
            if video.isReadyForMoreMediaData, let copy = try? CMSampleBuffer(copying: lastFrame, withNewTiming: [timing]) {
                video.append(copy)
            }
            writer.endSession(atSourceTime: time)
        }
        video.markAsFinished()
        audio?.markAsFinished()
        writer.finishWriting { [self] in
            if writer.status == .completed {
                completion(.success(url))
            } else {
                try? FileManager.default.removeItem(at: url)
                completion(.failure(writer.error ?? CocoaError(.fileWriteUnknown)))
            }
        }
    }

    // For a cancelled recording: stops writing and deletes the file.
    func discard() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func status(of buffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }
}
