import Foundation

struct ProbeError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

enum Prober {
    private struct Output: Decodable {
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
            let profile: String?
            let pix_fmt: String?
            let width: Int?
            let height: Int?
            let sample_rate: String?
            let channels: Int?
            let extradata_hash: String?
            let disposition: [String: Int]?
            let side_data_list: [SideData]?
        }

        struct SideData: Decodable {
            let rotation: Double?
        }

        struct Format: Decodable {
            let duration: String?
            let tags: [String: String]?
        }

        let streams: [Stream]
        let format: Format
    }

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let appleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    static func probeAll(_ urls: [URL], ffprobe: URL) async -> [(URL, Clip?)] {
        await withTaskGroup(of: (URL, Clip?).self) { group in
            for url in urls {
                group.addTask { (url, try? probe(url, ffprobe: ffprobe)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    static func probe(_ url: URL, ffprobe: URL) throws -> Clip {
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_data_hash", "SHA256", url.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, let info = try? JSONDecoder().decode(Output.self, from: data) else {
            throw ProbeError("not a readable video")
        }
        let videos = info.streams.filter { $0.codec_type == "video" }
        guard let videoIndex = videos.firstIndex(where: { $0.disposition?["attached_pic"] != 1 }),
              let width = videos[videoIndex].width, let height = videos[videoIndex].height, width > 0, height > 0 else {
            throw ProbeError("no video track")
        }
        guard let duration = info.format.duration.flatMap(Double.init), duration > 0 else {
            throw ProbeError("unknown duration")
        }

        let rotation = Int(videos[videoIndex].side_data_list?.compactMap(\.rotation).first ?? 0)
        let sideways = abs(rotation) % 180 == 90
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        return Clip(
            url: url,
            date: recordingDate(info.format.tags ?? [:], url: url),
            duration: duration,
            width: sideways ? height : width,
            height: sideways ? width : height,
            videoStream: videoIndex,
            audioStreams: info.streams.filter { $0.codec_type == "audio" }.count,
            fileSize: Int64(fileSize),
            copyFormat: copyFormat(info.streams, rotation: rotation)
        )
    }

    // Joining files as they are needs every track to match exactly, down to the encoder settings in the extradata.
    private static func copyFormat(_ streams: [Output.Stream], rotation: Int) -> String? {
        let tracks = streams.filter { $0.disposition?["attached_pic"] != 1 && ($0.codec_type == "video" || $0.codec_type == "audio") }
        let copyable = tracks.allSatisfy { track in
            track.codec_type == "video" ? ["h264", "hevc"].contains(track.codec_name ?? "") : track.codec_name == "aac"
        }
        guard copyable, tracks.contains(where: { $0.codec_type == "video" }) else { return nil }
        let parts = tracks.map { track in
            [track.codec_type, track.codec_name, track.profile, track.pix_fmt, track.width.map(String.init), track.height.map(String.init),
             track.sample_rate, track.channels.map(String.init), track.extradata_hash].map { $0 ?? "-" }.joined(separator: ":")
        }
        return (parts + ["rotation:\(rotation)"]).joined(separator: "|")
    }

    private static func recordingDate(_ tags: [String: String], url: URL) -> Date {
        if let value = tags["com.apple.quicktime.creationdate"], let date = appleFormatter.date(from: value) {
            return date
        }
        if let value = tags["creation_time"], let date = utcFormatter.date(from: String(value.prefix(19))),
           date > Date(timeIntervalSince1970: 0) {
            return date
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }
}
