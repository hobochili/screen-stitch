import AppKit
import ScreenCaptureKit
import Testing

// These record the real screen, so they need Screen Recording permission and a Mac nobody's using for a few seconds.
// `./test.sh --capture` runs them as Screen Stitch, which has that permission; otherwise they're skipped. It names a
// folder that keeps each test's clip, for a look when one fails.
private let keptClips = ProcessInfo.processInfo.environment["SCREEN_STITCH_CAPTURE"].map { URL(fileURLWithPath: $0) }
private let capturing = keptClips != nil

// A plain magenta window: nothing else on screen is likely to look like it.
@MainActor
private final class MagentaWindow {
    let window: NSWindow

    init(size: CGSize) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let visible = NSScreen.main!.visibleFrame
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        window.level = .floating
        window.orderFrontRegardless()
        window.display()
    }

    func close() {
        window.orderOut(nil)
    }

    // The window server takes a moment to list a new window, and a moment longer to give it its size.
    func shareable() async throws -> SCWindow {
        let id = CGWindowID(window.windowNumber)
        for _ in 0..<20 {
            let windows = try await SCShareableContent.current.windows
            if let found = windows.first(where: { $0.windowID == id && $0.isOnScreen && $0.frame.width > 0 }) {
                return found
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CommandError(description: "the test window never showed up")
    }

    // In points from the top-left corner of its display, the way an area is recorded.
    var area: CGRect {
        let screen = window.screen!.frame
        return CGRect(x: window.frame.minX - screen.minX, y: screen.maxY - window.frame.maxY,
                      width: window.frame.width, height: window.frame.height)
    }
}

private func isMagenta(_ color: (y: Double, u: Double, v: Double)) -> Bool {
    color.u > 190 && color.v > 200
}

// Records with the app's Recorder, doing `meanwhile` while it records, and returns the clip and how long it ran.
private func record(_ filter: SCContentFilter, area: CGRect? = nil, into folder: TemporaryFolder,
                    keepingAs name: String = #function,
                    meanwhile: (Recorder) async throws -> Void) async throws -> (url: URL, seconds: Double) {
    let (events, continuation) = AsyncStream<Recorder.Event>.makeStream()
    let recorder = Recorder(folder: folder.url, microphone: false) { continuation.yield($0) }
    var next = events.makeAsyncIterator()
    recorder.record(filter, area: area)
    guard case .started? = await next.next() else {
        throw CommandError(description: "recording didn't start")
    }
    let start = Date()
    try await meanwhile(recorder)
    recorder.stop()
    let seconds = Date().timeIntervalSince(start)
    switch await next.next() {
    case let .finished(url?)?:
        if let keptClips {
            let kept = keptClips.appendingPathComponent(name.replacingOccurrences(of: "()", with: "") + ".mov")
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.copyItem(at: url, to: kept)
        }
        return (url, seconds)
    case let .failed(message)?: throw CommandError(description: message)
    default: throw CommandError(description: "recording ended without a clip")
    }
}

@MainActor
@Suite(.serialized, .enabled(if: capturing, "records the screen; run with ./test.sh --capture"), .timeLimit(.minutes(1)))
struct CaptureTests {
    @Test func windowRecordingIsTheWindowForAsLongAsItRan() async throws {
        let folder = try TemporaryFolder()
        let magenta = MagentaWindow(size: CGSize(width: 400, height: 300))
        defer { magenta.close() }
        let filter = SCContentFilter(desktopIndependentWindow: try await magenta.shareable())
        let clip = try await record(filter, into: folder) { _ in
            try await Task.sleep(for: .seconds(1.5))
        }
        let info = try videoInfo(clip.url)
        let scale = Int(filter.pointPixelScale)
        #expect(info.width == 400 * scale && info.height == 300 * scale)
        #expect(abs(info.duration - clip.seconds) < 0.3, "clip lasts \(info.duration)s, recorded for \(clip.seconds)s")
        #expect(isMagenta(try averageColor(of: clip.url, at: 0.5)))
    }

    // Resizing used to end the recording. Now the clip keeps going at its first size, with the window centered.
    @Test func resizedWindowKeepsRecordingCentered() async throws {
        let folder = try TemporaryFolder()
        let magenta = MagentaWindow(size: CGSize(width: 400, height: 300))
        defer { magenta.close() }
        let filter = SCContentFilter(desktopIndependentWindow: try await magenta.shareable())
        let clip = try await record(filter, into: folder) { recorder in
            try await Task.sleep(for: .seconds(0.7))
            let frame = magenta.window.frame
            magenta.window.setFrame(CGRect(x: frame.midX - 100, y: frame.midY - 75, width: 200, height: 150), display: true)
            // The app hears about the new size from the frame it draws around the window.
            recorder.fit(windowSize: CGSize(width: 200, height: 150))
            try await Task.sleep(for: .seconds(1))
        }
        let info = try videoInfo(clip.url)
        let scale = Int(filter.pointPixelScale)
        #expect(info.width == 400 * scale && info.height == 300 * scale)
        #expect(abs(info.duration - clip.seconds) < 0.3, "clip lasts \(info.duration)s, recorded for \(clip.seconds)s")
        let visible = try #require(try lastVisibleArea(of: clip.url), "no reading from the last frame")
        let parts = visible.split(separator: ":").compactMap { Int($0) }
        let expected = [200 * scale, 150 * scale, 100 * scale, 75 * scale]
        #expect(parts.count == 4 && zip(parts, expected).allSatisfy { abs($0 - $1) <= 4 }, "visible area \(visible)")
    }

    // Screen Stitch's own windows stay out of display recordings, so the magenta window shouldn't be in this one.
    @Test func displayRecordingLeavesOutScreenStitch() async throws {
        let folder = try TemporaryFolder()
        let magenta = MagentaWindow(size: CGSize(width: 400, height: 300))
        defer { magenta.close() }
        _ = try await magenta.shareable()
        let content = try await SCShareableContent.current
        let displayID = try #require(magenta.window.screen?.displayID)
        let display = try #require(content.displays.first { $0.displayID == displayID })
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let clip = try await record(filter, area: magenta.area, into: folder) { _ in
            try await Task.sleep(for: .seconds(1))
        }
        #expect(!isMagenta(try averageColor(of: clip.url, at: 0.5)))
    }
}
