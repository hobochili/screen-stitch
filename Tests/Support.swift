import Foundation
import Testing

// test.sh builds the app and these tests into one executable; this replaces the app's entry point.
@main
enum TestRunner {
    // The app's settings go to a throwaway domain, removed when the run ends, instead of the runner's own.
    static func main() async {
        UserDefaults.standard.removePersistentDomain(forName: "local.screen-stitch.tests")
        StitchModel.defaults = UserDefaults(suiteName: "local.screen-stitch.tests")!
        atexit { UserDefaults.standard.removePersistentDomain(forName: "local.screen-stitch.tests") }
        await Testing.__swiftPMEntryPoint() as Never
    }
}

let tools = Tools.locate()

func makeClip(
    _ name: String = "clip.mov",
    width: Int = 1920,
    height: Int = 1080,
    duration: Double = 5,
    audioStreams: Int = 0,
    videoStream: Int = 0,
    date: Date = Date(timeIntervalSince1970: 0)
) -> Clip {
    Clip(
        url: URL(fileURLWithPath: "/tmp/\(name)"),
        date: date,
        duration: duration,
        width: width,
        height: height,
        videoStream: videoStream,
        audioStreams: audioStreams,
        fileSize: 0
    )
}

// A folder that's deleted when the test finishes.
final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-stitch-tests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}

struct CommandError: Error, CustomStringConvertible {
    let description: String
}

// Runs a tool and returns its standard output.
@discardableResult
func run(_ tool: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = tool
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errors = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CommandError(description: "\(tool.lastPathComponent) failed: \(String(decoding: errors, as: UTF8.self))")
    }
    return String(decoding: output, as: UTF8.self)
}

// Makes a solid-color test video with FFmpeg, optionally with a tone, plus any extra output options.
func makeVideo(_ url: URL, width: Int, height: Int, seconds: Double = 1, color: String = "orange", audio: Bool = false,
               options: [String] = []) throws {
    var arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=\(color):s=\(width)x\(height):d=\(seconds):r=30"]
    if audio {
        arguments += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"]
    }
    arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p"] + (audio ? ["-c:a", "aac"] : []) + options + [url.path]
    try run(tools!.ffmpeg, arguments)
}

// The non-black part of the frame at `time`, as FFmpeg's cropdetect reports it: "width:height:x:y".
func visibleArea(of url: URL, at time: Double) throws -> String? {
    try cropReadings(["-ss", String(time), "-i", url.path, "-frames:v", "3", "-vf", "cropdetect=limit=24:round=2:skip=0"])
        .last
}

// The same for the clip's last frame. It reads every frame rather than seeking, since a still screen gives few frames
// and a seek past the last one reads nothing.
func lastVisibleArea(of url: URL) throws -> String? {
    try cropReadings(["-i", url.path, "-vf", "cropdetect=limit=24:round=2:skip=0:reset=1"]).last
}

private func cropReadings(_ arguments: [String]) throws -> [String] {
    try filterLog(arguments).components(separatedBy: "crop=").dropFirst()
        .compactMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) }
}

// What FFmpeg's filters print while it decodes to nowhere.
private func filterLog(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = tools!.ffmpeg
    process.arguments = ["-v", "info"] + arguments + ["-f", "null", "-"]
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let log = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return log
}

struct VideoInfo {
    let width: Int
    let height: Int
    let duration: Double
    let audioChannels: Int?
    let audioSampleRate: Int?
    let audioStart: Double?
}

func videoInfo(_ url: URL) throws -> VideoInfo {
    struct Output: Decodable {
        struct Stream: Decodable {
            let codec_type: String
            let width: Int?
            let height: Int?
            let channels: Int?
            let sample_rate: String?
            let start_time: String?
        }

        struct Format: Decodable {
            let duration: String
        }

        let streams: [Stream]
        let format: Format
    }
    let json = try run(tools!.ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
    let output = try JSONDecoder().decode(Output.self, from: Data(json.utf8))
    let video = output.streams.first { $0.codec_type == "video" }
    let audio = output.streams.first { $0.codec_type == "audio" }
    return VideoInfo(
        width: video?.width ?? 0,
        height: video?.height ?? 0,
        duration: Double(output.format.duration) ?? 0,
        audioChannels: audio?.channels,
        audioSampleRate: audio?.sample_rate.flatMap { Int($0) },
        audioStart: audio?.start_time.flatMap { Double($0) }
    )
}

// Average luma (0–255) of the frame at `time`.
func averageBrightness(of url: URL, at time: Double) throws -> Double {
    try averageColor(of: url, at: time).y
}

// Average Y, U and V (0–255) of the frame at `time`, from FFmpeg's signalstats.
func averageColor(of url: URL, at time: Double) throws -> (y: Double, u: Double, v: Double) {
    guard let color = try colorReadings(["-ss", String(time), "-i", url.path, "-frames:v", "1"]).last else {
        throw CommandError(description: "no color reading for \(url.lastPathComponent)")
    }
    return color
}

// The same for every frame. A still screen gives few frames, so a seek can land past the last one and read nothing.
func frameColors(of url: URL) throws -> [(y: Double, u: Double, v: Double)] {
    try colorReadings(["-i", url.path])
}

private func colorReadings(_ input: [String]) throws -> [(y: Double, u: Double, v: Double)] {
    let log = try filterLog(input + ["-vf", "signalstats,metadata=print"])
    return log.components(separatedBy: "] frame:").dropFirst().compactMap { frame in
        func reading(_ key: String) -> Double? {
            frame.components(separatedBy: "signalstats.\(key)=").dropFirst().first?
                .split(whereSeparator: \.isNewline).first.flatMap { Double($0) }
        }
        guard let y = reading("YAVG"), let u = reading("UAVG"), let v = reading("VAVG") else { return nil }
        return (y, u, v)
    }
}
