import AppKit
import AVFoundation
import ScreenCaptureKit

final class Recorder: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    enum Event {
        case started
        case finished(URL?)
        case cancelled
        case failed(String)
    }

    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return formatter
    }()

    private let folder: URL
    private let microphone: Bool
    private let onEvent: @Sendable (Event) -> Void
    private let frames = DispatchQueue(label: "screen-stitch.frames")
    private let lock = NSLock()
    private var stream: SCStream?
    private var clip: ClipWriter?
    private var ended = false
    private var configuration: SCStreamConfiguration?
    private var pixelsPerPoint: CGFloat = 1
    private var pendingWindowSize: CGSize?
    private var fitting = false

    init(folder: URL, microphone: Bool, onEvent: @escaping @Sendable (Event) -> Void) {
        self.folder = folder
        self.microphone = microphone
        self.onEvent = onEvent
    }

    func pick() {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        configuration.allowsChangingSelectedContent = false
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    // The time is taken at the click, so the clip lasts until then even if the screen was still at the end.
    func stop() {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        lock.withLock { stream }?.stopCapture { [self] _ in finish(at: time) }
    }

    // The macOS picker was cancelled, possibly after recording had started: stop and keep nothing.
    func cancel() {
        end(.cancelled)
        discard()
    }

    private func discard() {
        let (stream, clip) = lock.withLock {
            defer { self.clip = nil }
            return (self.stream, self.clip)
        }
        stream?.stopCapture { _ in }
        frames.async { clip?.discard() }
    }

    // `area` is a region of a display, in points from its top-left corner.
    func record(_ filter: SCContentFilter, area: CGRect? = nil) {
        start(filter, area: area)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        end(.cancelled)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard lock.withLock({ self.stream == nil }) else { return }
        start(filter)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        end(.failed(error.localizedDescription))
    }

    // The floating controls are marked unshareable; with Screen Recording permission, display captures also
    // exclude this app outright, which covers macOS versions that don't honor that flag.
    private func start(_ picked: SCContentFilter, area: CGRect? = nil) {
        let points = area?.size ?? picked.contentRect.size
        let size = CGSize(width: points.width * CGFloat(picked.pointPixelScale), height: points.height * CGFloat(picked.pointPixelScale))
        guard #available(macOS 15.2, *), picked.style == .display, CGPreflightScreenCaptureAccess(),
              let display = picked.includedDisplays.first else {
            record(picked, size: size, area: area)
            return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [self] content, _ in
            let ours = content?.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier } ?? []
            let filter = ours.isEmpty ? picked : SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
            record(filter, size: size, area: area)
        }
    }

    private func record(_ filter: SCContentFilter, size: CGSize, area: CGRect?) {
        guard !lock.withLock({ ended }) else { return }
        // H.264 tops out at 4096 pixels; screencapture downscales large displays the same way.
        let fit = min(1, 4096 / max(size.width, size.height))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width * fit / 2) * 2
        configuration.height = Int(size.height * fit / 2) * 2
        // A window that's closing or minimizing can have no size, and the writer can't take that.
        guard configuration.width > 0, configuration.height > 0 else {
            end(.failed("The window isn't on screen. Bring it back, or pick something else to record."))
            return
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureMicrophone = microphone
        if let area {
            configuration.sourceRect = area
        }

        let url = folder.appendingPathComponent("Screen Stitch \(Self.fileDate.string(from: Date())).mov")
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let clip: ClipWriter
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
            if microphone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: frames)
            }
            clip = try ClipWriter(url: url, width: configuration.width, height: configuration.height, microphone: microphone)
        } catch {
            end(.failed(error.localizedDescription))
            return
        }
        lock.withLock {
            self.stream = stream
            self.clip = clip
            self.configuration = configuration
            pixelsPerPoint = CGFloat(filter.pointPixelScale) * fit
        }
        stream.startCapture { [self] error in
            if let error {
                end(.failed(error.localizedDescription))
            } else if lock.withLock({ ended }) {
                discard()
            } else {
                onEvent(.started)
            }
        }
    }

    // A window resized mid-recording keeps its scale and is centered in the frame, instead of being stretched or pinned
    // to a corner. Updates are coalesced so a live resize doesn't queue one per tick.
    func fit(windowSize: CGSize) {
        let idle = lock.withLock {
            pendingWindowSize = windowSize
            defer { fitting = true }
            return !fitting
        }
        if idle { applyFit() }
    }

    private func applyFit() {
        let next: (SCStream, SCStreamConfiguration, CGSize, CGFloat)? = lock.withLock {
            guard let stream, let configuration, let size = pendingWindowSize else {
                fitting = false
                return nil
            }
            pendingWindowSize = nil
            return (stream, configuration, size, pixelsPerPoint)
        }
        guard case let (stream, configuration, size, scale)? = next else { return }
        let width = CGFloat(configuration.width)
        let height = CGFloat(configuration.height)
        let fit = min(1, width / (size.width * scale), height / (size.height * scale))
        let content = CGSize(width: (size.width * scale * fit).rounded(), height: (size.height * scale * fit).rounded())
        configuration.destinationRect = CGRect(
            x: ((width - content.width) / 2).rounded(), y: ((height - content.height) / 2).rounded(),
            width: content.width, height: content.height
        )
        stream.updateConfiguration(configuration) { [self] _ in applyFit() }
    }

    // Stopped from the system's screen-sharing menu, or the recorded window closed.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let clip = lock.withLock({ clip }) else { return }
        if let error = clip.append(sampleBuffer, of: type) {
            end(.failed(error.localizedDescription))
        }
    }

    // Queued behind any samples still being delivered. Both Stop and the stream stopping on its own can call this, so
    // the first call takes the writer and later samples and calls find none.
    private func finish(at time: CMTime) {
        frames.async { [self] in
            let clip = lock.withLock {
                defer { self.clip = nil }
                return self.clip
            }
            clip?.finish(at: time) { [self] result in
                switch result {
                case let .success(url): end(.finished(url))
                case let .failure(error): end(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func end(_ event: Event) {
        let first = lock.withLock {
            defer { ended = true }
            return !ended
        }
        guard first else { return }
        if case .failed = event {
            stop()
        }
        onEvent(event)
        DispatchQueue.main.async { [self] in
            SCContentSharingPicker.shared.remove(self)
            SCContentSharingPicker.shared.isActive = false
        }
    }
}
