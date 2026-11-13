@preconcurrency import AVFoundation
import Vision

// Where a piece of hidden text was seen as it moved through a clip. Boxes are fractions of the frame, measured from its
// top left.
struct TextTrack: Hashable, Sendable, Codable {
    struct Sighting: Hashable, Sendable, Codable {
        var time: Double
        var box: CGRect
    }

    var text: String
    var sightings: [Sighting]
    // Shorter than `lead` when the text jumped here from another place, or on from here, as when a new message pushes a
    // chat up, so the box doesn't sit over whatever is in the way.
    var leadIn: Double?
    var leadOut: Double?

    // The box is held this long before the first sighting and after the last, moving the way the text was, so text
    // sliding in past the edge of a window or fading in is covered before it can be read.
    static let lead = 0.5
    // Faster than this, a measured movement is noise, as when a window resizes, and the box holds still instead.
    static let maxSpeed = 1.0

    // The shortest lead into a place the text jumped to, enough to cover it fading in.
    static let jumpLead = 0.15

    var start: Double { sightings[0].time - (leadIn ?? Self.lead) }
    var end: Double { sightings[sightings.count - 1].time + (leadOut ?? Self.lead) }

    func box(at time: Double) -> CGRect? {
        guard time >= start, time <= end else { return nil }
        let first = sightings[0], last = sightings[sightings.count - 1]
        if time <= first.time {
            return first.box.offsetBy(velocity: velocity(from: 0, forward: true), seconds: time - first.time)
        }
        if time >= last.time {
            return last.box.offsetBy(velocity: velocity(from: sightings.count - 1, forward: false), seconds: time - last.time)
        }
        let after = sightings.partitionIndex { $0.time > time }
        let a = sightings[after - 1], b = sightings[after]
        let f = (time - a.time) / (b.time - a.time)
        return CGRect(x: a.box.minX + (b.box.minX - a.box.minX) * f, y: a.box.minY + (b.box.minY - a.box.minY) * f,
                      width: a.box.width + (b.box.width - a.box.width) * f, height: a.box.height + (b.box.height - a.box.height) * f)
    }

    // Quick and careful readings box the same text at slightly different spots and sizes, so boxes would flicker. Each
    // still stretch gets one box covering all its readings, at the typical reading's height so it stays on its line.
    func steadied() -> TextTrack {
        var runs: [(first: Int, last: Int, box: CGRect)] = []
        for (index, sighting) in sightings.enumerated() {
            let anchor = runs.last.map { sightings[$0.first].box }
            if let anchor, abs(sighting.box.midX - anchor.midX) <= min(sighting.box.width, anchor.width) / 2,
               abs(sighting.box.midY - anchor.midY) <= min(sighting.box.height, anchor.height) / 2 {
                runs[runs.count - 1].last = index
            } else {
                runs.append((index, index, sighting.box))
            }
        }
        func middle(_ values: [CGFloat]) -> CGFloat {
            values.sorted()[values.count / 2]
        }
        for index in runs.indices {
            let boxes = sightings[runs[index].first...runs[index].last].map(\.box)
            // Careful readings' taller boxes take in the line spacing, so height comes from the typical reading instead.
            let height = middle(boxes.map(\.height))
            let minY = (boxes.map(\.midY).min() ?? 0) - height / 2, maxY = (boxes.map(\.midY).max() ?? 0) + height / 2
            let minX = boxes.map(\.minX).min() ?? 0, maxX = boxes.map(\.maxX).max() ?? 0
            runs[index].box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        var steady = self
        for run in runs {
            let from = sightings[run.first].time - Self.lead, to = sightings[run.last].time + Self.lead
            let near = runs.filter { sightings[$0.last].time >= from && sightings[$0.first].time <= to }
            let width = near.map(\.box.width).max() ?? run.box.width
            let height = near.map(\.box.height).max() ?? run.box.height
            let box = CGRect(x: run.box.midX - width / 2, y: run.box.midY - height / 2, width: width, height: height)
            for index in run.first...run.last {
                steady.sightings[index].box = box
            }
        }
        return steady
    }

    // Whether the text was read in the frame at this time, rather than its box being held or carried along.
    func isSighted(at time: Double) -> Bool {
        let index = sightings.partitionIndex { $0.time >= time - 0.0005 }
        return index < sightings.count && sightings[index].time <= time + 0.0005
    }

    // Measured over at least a fifth of a second, since boxes found a frame apart jitter by a pixel or two. Without
    // that much to go on, or when it's implausibly fast or the text jumped on the way, the box holds still.
    func velocity(from index: Int, forward: Bool) -> CGVector {
        let anchor = sightings[index]
        let others = forward ? Array(sightings[(index + 1)...]) : sightings[..<index].reversed()
        var previous = anchor
        var reached: Sighting?
        for other in others {
            let seconds = abs(other.time - previous.time)
            if seconds > 0, max(abs(other.box.minX - previous.box.minX), abs(other.box.minY - previous.box.minY)) / seconds > Self.maxSpeed {
                return .zero
            }
            if abs(other.time - anchor.time) >= 0.2 {
                reached = other
                break
            }
            previous = other
        }
        guard let other = reached else { return .zero }
        let seconds = other.time - anchor.time
        let velocity = CGVector(dx: (other.box.minX - anchor.box.minX) / seconds, dy: (other.box.minY - anchor.box.minY) / seconds)
        return abs(velocity.dx) > Self.maxSpeed || abs(velocity.dy) > Self.maxSpeed ? .zero : velocity
    }
}

extension CGRect {
    fileprivate func offsetBy(velocity: CGVector, seconds: Double) -> CGRect {
        offsetBy(dx: velocity.dx * seconds, dy: velocity.dy * seconds)
    }
}

extension Array {
    // The first index whose element matches, in a list where every match comes after every non-match.
    fileprivate func partitionIndex(where matches: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if matches(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

// Links what text recognition found in each frame into tracks, one per place the text appears.
enum TextTracker {
    struct Found: Hashable, Sendable, Codable {
        var text: String
        var box: CGRect
    }

    struct Frame: Sendable, Codable {
        var time: Double
        var found: [Found]
        var careful = false
    }

    // A track that loses its text for longer than this ends. Shorter gaps are covered by holding the box.
    static let maxGap = 1.0
    // Gaps shorter than this between one track and the next are read again carefully, since something passing over the
    // text can hide it for a few seconds. A track that picks up again in the same place is joined across the gap.
    static let recheckGap = 5.0

    // Readings go to tracks closest pair first, so when one of several rows showing the same text goes unread for a
    // frame, its track holds its box instead of taking a neighbouring row's reading.
    static func tracks(for text: String, in frames: [Frame]) -> [TextTrack] {
        var done: [TextTrack] = []
        var active: [TextTrack] = []
        for frame in frames {
            let found = frame.found.filter { $0.text == text }
            var pairs: [(track: Int, reading: Int, distance: Double)] = []
            for (trackIndex, track) in active.enumerated() {
                let expected = predictedBox(of: track, at: frame.time)
                for (readingIndex, reading) in found.enumerated() where isNear(reading.box, expected) {
                    pairs.append((trackIndex, readingIndex, distance(reading.box, expected)))
                }
            }
            var matchedTracks: Set<Int> = [], matchedReadings: Set<Int> = []
            for pair in pairs.sorted(by: { $0.distance < $1.distance })
            where !matchedTracks.contains(pair.track) && !matchedReadings.contains(pair.reading) {
                active[pair.track].sightings.append(.init(time: frame.time, box: found[pair.reading].box))
                matchedTracks.insert(pair.track)
                matchedReadings.insert(pair.reading)
            }
            for (track, reading) in jumps(of: active, to: found, in: frame, matchedTracks: matchedTracks, matchedReadings: matchedReadings) {
                active[track].sightings.append(.init(time: frame.time, box: found[reading].box))
                matchedTracks.insert(track)
                matchedReadings.insert(reading)
            }
            var still: [TextTrack] = []
            for (index, track) in active.enumerated() {
                if matchedTracks.contains(index) || frame.time - track.sightings[track.sightings.count - 1].time <= maxGap {
                    still.append(track)
                } else {
                    done.append(track)
                }
            }
            for (index, reading) in found.enumerated() where !matchedReadings.contains(index) {
                still.append(TextTrack(text: text, sightings: [.init(time: frame.time, box: reading.box)]))
            }
            active = still
        }
        return (done + active).sorted { $0.sightings[0].time < $1.sightings[0].time }
    }

    // Text that jumps several lines at once, as a mouse wheel scrolls, is followed to an unclaimed reading in its column.
    // When several tracks jump, the shift most of them share wins, since a scroll moves everything the same amount.
    private static func jumps(of active: [TextTrack], to found: [Found], in frame: Frame, matchedTracks: Set<Int>,
                              matchedReadings: Set<Int>) -> [(track: Int, reading: Int)] {
        var candidates: [(track: Int, reading: Int, shift: Double)] = []
        for (trackIndex, track) in active.enumerated() where !matchedTracks.contains(trackIndex) {
            let last = track.sightings[track.sightings.count - 1]
            guard frame.time - last.time <= TextTrack.lead else { continue }
            for (readingIndex, reading) in found.enumerated()
            where !matchedReadings.contains(readingIndex) && abs(reading.box.midX - last.box.midX) < 0.03 {
                candidates.append((trackIndex, readingIndex, reading.box.midY - last.box.midY))
            }
        }
        func support(_ shift: Double) -> Int {
            candidates.filter { abs($0.shift - shift) < 0.01 }.count
        }
        guard let shift = candidates.map(\.shift).max(by: { (support($0), -abs($0)) < (support($1), -abs($1)) }) else { return [] }
        var tracks: Set<Int> = [], readings: Set<Int> = []
        var result: [(track: Int, reading: Int)] = []
        for candidate in candidates.sorted(by: { abs($0.shift - shift) < abs($1.shift - shift) })
        where abs(candidate.shift - shift) < 0.01 && !tracks.contains(candidate.track) && !readings.contains(candidate.reading) {
            result.append((candidate.track, candidate.reading))
            tracks.insert(candidate.track)
            readings.insert(candidate.reading)
        }
        return result
    }

    // The tracks to cover once re-reading is done. One that picks up in the same place within `recheckGap` is joined
    // across the gap. When text turns up elsewhere within the lead, the old box stops and the new one starts at the jump.
    static func covering(_ tracks: [TextTrack]) -> [TextTrack] {
        var joined: [TextTrack] = []
        for track in tracks.sorted(by: { $0.sightings[0].time < $1.sightings[0].time }) {
            let first = track.sightings[0]
            if let index = joined.lastIndex(where: { other in
                let last = other.sightings[other.sightings.count - 1]
                return first.time > last.time && first.time - last.time < recheckGap && isNear(first.box, last.box)
            }) {
                joined[index].sightings += track.sightings
            } else {
                joined.append(track)
            }
        }
        for a in joined.indices {
            let ended = joined[a].sightings[joined[a].sightings.count - 1].time
            let next = joined.indices.filter { b in
                let started = joined[b].sightings[0].time
                return started > ended && started - ended < TextTrack.lead
            }.min { joined[$0].sightings[0].time < joined[$1].sightings[0].time }
            guard let b = next else { continue }
            let gap = joined[b].sightings[0].time - ended
            joined[a].leadOut = gap
            joined[b].leadIn = min(joined[b].leadIn ?? TextTrack.lead, max(gap, TextTrack.jumpLead))
        }
        return joined
    }

    // Frames where a track lost its text for a moment, the lead-in and lead-out around each track, and short gaps between
    // tracks: the ones worth reading again carefully.
    static func timesToRecheck(_ tracks: [TextTrack], in frames: [Frame]) -> Set<Double> {
        var times: Set<Double> = []
        for track in tracks {
            let seen = Set(track.sightings.map(\.time))
            for frame in frames where frame.time >= track.start && frame.time <= track.end && !seen.contains(frame.time) {
                times.insert(frame.time)
            }
        }
        var covered: [ClosedRange<Double>] = []
        for track in tracks.sorted(by: { $0.start < $1.start }) {
            if let last = covered.last, track.start <= last.upperBound {
                covered[covered.count - 1] = last.lowerBound...max(last.upperBound, track.end)
            } else {
                covered.append(track.start...track.end)
            }
        }
        for (before, after) in zip(covered, covered.dropFirst()) where after.lowerBound - before.upperBound < recheckGap {
            for frame in frames where frame.time > before.upperBound && frame.time < after.lowerBound {
                times.insert(frame.time)
            }
        }
        return times
    }

    // Everything in both readings, without counting a place twice.
    static func merge(_ a: [Found], _ b: [Found]) -> [Found] {
        a + b.filter { found in !a.contains { $0.text == found.text && overlaps($0.box, found.box) } }
    }

    // Carries the box along at the speed the text was moving, held still when that isn't known.
    private static func predictedBox(of track: TextTrack, at time: Double) -> CGRect {
        let last = track.sightings[track.sightings.count - 1]
        return last.box.offsetBy(velocity: track.velocity(from: track.sightings.count - 1, forward: false), seconds: time - last.time)
    }

    private static func isNear(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midX - b.midX) < 0.03 && abs(a.midY - b.midY) < 0.08
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        return !shared.isNull && shared.width * shared.height > 0.5 * min(a.width * a.height, b.width * b.height)
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> Double {
        (a.midX - b.midX) * (a.midX - b.midX) + (a.midY - b.midY) * (a.midY - b.midY)
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isSet: Bool { lock.withLock { cancelled } }

    func set() {
        lock.withLock { cancelled = true }
    }
}

// Stops a search, or moves its worker processes into the background band while a recording needs the processors.
final class SearchControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var background = false
    private var workers: [ObjectIdentifier: Process] = [:]

    var isStopped: Bool { lock.withLock { stopped } }

    func stop() {
        let running: [Process] = lock.withLock {
            stopped = true
            return Array(workers.values)
        }
        running.forEach { $0.terminate() }
    }

    func setBackground(_ on: Bool) {
        lock.withLock {
            guard background != on else { return }
            background = on
            workers.values.forEach { Self.setBackground(on, $0) }
        }
    }

    func add(_ process: Process) {
        lock.withLock {
            workers[ObjectIdentifier(process)] = process
            if background { Self.setBackground(true, process) }
        }
    }

    func remove(_ process: Process) {
        lock.withLock {
            workers[ObjectIdentifier(process)] = nil
        }
    }

    // The background band runs a process at low priority, mostly on the efficiency cores, with its disk use throttled.
    static func setBackground(_ on: Bool, _ process: Process) {
        guard process.isRunning else { return }
        _ = setpriority(PRIO_DARWIN_PROCESS, id_t(process.processIdentifier), on ? PRIO_DARWIN_BG : 0)
    }
}

enum TextFinderError: LocalizedError {
    case noVideo
    case rotated
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: "It has no video to read."
        case .rotated: "It's rotated, and Screen Stitch can't find text in rotated video yet."
        case let .failed(message): message
        }
    }
}

// Finds text in every frame with Vision. Quick readings can miss a line for as long as it's on screen, so careful ones
// run every half second and when the picture changes a lot, then wherever a track lost its text, until they find no more.
enum TextFinder {
    enum Pass: String {
        case careful
        // Quick, with careful readings as `carefulInterval` and `changeInterval` allow.
        case sampled
    }

    static let carefulInterval = 0.5
    static let changeInterval = 0.15

    // The program that reads frames, run as several workers with --find-text, since Vision reads one frame at a time in
    // each process.
    nonisolated(unsafe) static var worker = Bundle.main.executableURL!
    // Told when a worker fails and its stretch is read again, for the Export Log.
    nonisolated(unsafe) static var onRetry: (@Sendable (String) -> Void)?

    static var workerCount: Int {
        max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    static func find(_ texts: [String], in url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in },
                     control: SearchControl = SearchControl()) async throws -> [String: [TextTrack]] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw TextFinderError.noVideo }
        let transform = try await track.load(.preferredTransform)
        guard transform.a == 1, transform.d == 1, transform.b == 0, transform.c == 0 else { throw TextFinderError.rotated }
        let duration = try await asset.load(.duration).seconds
        // The first pass is most of the work. The careful re-reading only reads the frames it has to.
        let reporter = ProgressReporter { progress(0.8 * $0) }
        let rereadReporter = ProgressReporter { progress(0.8 + 0.2 * $0) }

        // Chunks are handed out as workers free up, so a busy stretch doesn't hold up the rest.
        let chunkLength = min(20, max(2, duration / Double(workerCount)))
        let chunks = stride(from: 0.0, to: max(duration, 0.001), by: chunkLength).map { start in
            (start, start + chunkLength >= duration ? duration + 1 : start + chunkLength)
        }
        let next = Counter()
        var frames = try await withThrowingTaskGroup(of: [TextTracker.Frame].self) { group in
            for _ in 0..<min(workerCount, chunks.count) {
                group.addTask {
                    var read: [TextTracker.Frame] = []
                    while case let index = next.increment() - 1, index < chunks.count {
                        let (start, end) = chunks[index]
                        read += try await self.read(url, from: start, to: end, pass: .sampled, texts: texts, control: control) { time in
                            reporter.report(part: index, of: chunks.count, fraction: (time - start) / (end - start))
                        }
                    }
                    return read
                }
            }
            return try await group.reduce(into: []) { $0 += $1 }.sorted { $0.time < $1.time }
        }

        // Each round of careful re-reading can find text that opens new windows to read, so it goes on until a round adds
        // nothing, or three rounds.
        var readCarefully = Set(frames.filter(\.careful).map(\.time))
        for round in 0..<3 {
            let tracks = texts.flatMap { TextTracker.tracks(for: $0, in: frames) }
            let recheck = TextTracker.timesToRecheck(tracks, in: frames).subtracting(readCarefully)
            guard !recheck.isEmpty else { break }
            let done = Counter()
            let reread = try await withThrowingTaskGroup(of: [TextTracker.Frame].self) { group in
                for times in split(recheck, into: workerCount) {
                    group.addTask {
                        try await read(url, from: times[0], to: times[times.count - 1] + 0.001, pass: .careful, texts: texts,
                                       only: Set(times), control: control) { _ in
                            // Most rounds stop after the first, so it gets most of the bar, and the bar never stands still.
                            let shares = [0.8, 0.15, 0.05]
                            let fraction = shares[..<round].reduce(0, +) + shares[round] * Double(done.increment()) / Double(recheck.count)
                            rereadReporter.report(part: 0, of: 1, fraction: fraction)
                        }
                    }
                }
                return try await group.reduce(into: [Double: [TextTracker.Found]]()) { result, frames in
                    for frame in frames { result[frame.time] = frame.found }
                }
            }
            frames = frames.map { frame in
                guard let found = reread[frame.time] else { return frame }
                return TextTracker.Frame(time: frame.time, found: TextTracker.merge(found, frame.found), careful: true)
            }
            readCarefully.formUnion(recheck)
        }
        progress(1)
        return Dictionary(uniqueKeysWithValues: texts.map { ($0, TextTracker.covering(TextTracker.tracks(for: $0, in: frames))) })
    }

    // About the same number of times in each group, without splitting a run of times less than a second apart, since a
    // worker decodes each run as one stretch.
    static func split(_ times: Set<Double>, into count: Int) -> [[Double]] {
        let sorted = times.sorted()
        let share = max(1, (sorted.count + count - 1) / count)
        var groups: [[Double]] = []
        for time in sorted {
            if let last = groups.last?.last, time - last < 1 || groups[groups.count - 1].count < share {
                groups[groups.count - 1].append(time)
            } else {
                groups.append([time])
            }
        }
        return groups
    }

    // A worker that fails is run once more, since something outside the app can end one, and its stretch reads the same
    // either way.
    private static func read(_ url: URL, from start: Double, to end: Double, pass: Pass, texts: [String],
                             only: Set<Double>? = nil, control: SearchControl,
                             onFrame: @escaping @Sendable (Double) -> Void) async throws -> [TextTracker.Frame] {
        do {
            return try await readOnce(url, from: start, to: end, pass: pass, texts: texts, only: only, control: control, onFrame: onFrame)
        } catch let TextFinderError.failed(message) {
            onRetry?(String(format: "%@ Reading %.0f–%.0f s of “%@” again.", message, start, min(end, 1e6), url.lastPathComponent))
            return try await readOnce(url, from: start, to: end, pass: pass, texts: texts, only: only, control: control, onFrame: onFrame)
        }
    }

    private static func readOnce(_ url: URL, from start: Double, to end: Double, pass: Pass, texts: [String],
                                 only: Set<Double>?, control: SearchControl,
                                 onFrame: @escaping @Sendable (Double) -> Void) async throws -> [TextTracker.Frame] {
        var arguments = ["--find-text", url.path, pass.rawValue, "\(start)", "\(end)"]
        var timesFile: URL?
        if let only {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("screen-stitch-times-\(UUID().uuidString).txt")
            try only.map { "\($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            timesFile = file
            arguments += ["--times", file.path]
        }
        defer { timesFile.map { try? FileManager.default.removeItem(at: $0) } }

        let process = Process()
        process.executableURL = worker
        process.arguments = arguments + ["--"] + texts
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let exit = ExitStatus()
        process.terminationHandler = { exit.finish($0) }
        guard !control.isStopped else { throw CancellationError() }
        try process.run()
        control.add(process)
        defer {
            control.remove(process)
            if process.isRunning {
                process.terminate()
            }
        }
        // Read while it runs, so a worker with a lot to say can't fill the pipe and stall.
        let errorText = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }

        var frames: [TextTracker.Frame] = []
        let decoder = JSONDecoder()
        for try await line in output.fileHandleForReading.bytes.lines {
            if control.isStopped { throw CancellationError() }
            let frame = try decoder.decode(TextTracker.Frame.self, from: Data(line.utf8))
            frames.append(frame)
            onFrame(frame.time)
        }
        let ending = await exit.wait()
        if control.isStopped { throw CancellationError() }
        guard ending == "exit 0" else {
            let message = String(decoding: await errorText.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TextFinderError.failed(message.isEmpty ? "Text recognition stopped unexpectedly. (Details for support: \(ending).)" : message)
        }
        return frames
    }

    // A worker: reads its stretch of the video and prints each frame's findings as a line of JSON.
    // --find-text <video> <careful|sampled> <start> <end> [--times <file>] -- <text>...
    static func runAsWorker(_ arguments: [String]) -> Never {
        guard arguments.count >= 5, let pass = Pass(rawValue: arguments[1]), let start = Double(arguments[2]),
              let end = Double(arguments[3]), let separator = arguments.firstIndex(of: "--") else {
            FileHandle.standardError.write(Data("usage: --find-text <video> <careful|sampled> <start> <end> [--times <file>] -- <text>...\n".utf8))
            exit(2)
        }
        var only: Set<Double>?
        if let flag = arguments[..<separator].firstIndex(of: "--times"), flag + 1 < separator,
           let list = try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8) {
            only = Set(list.split(separator: "\n").compactMap { Double($0) })
        }
        let texts = Array(arguments[(separator + 1)...])
        let encoder = JSONEncoder()
        do {
            try readFrames(URL(fileURLWithPath: arguments[0]), from: start, to: end, pass: pass, texts: texts, only: only) { frame in
                if let data = try? encoder.encode(frame) {
                    FileHandle.standardOutput.write(data + Data("\n".utf8))
                }
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // Reads the frames from `start` up to `end`, or with `only`, just the stretches around those frames, so a worker
    // re-reading a few frames scattered through the video doesn't decode everything between them.
    private static func readFrames(_ url: URL, from start: Double, to end: Double, pass: Pass, texts: [String],
                                   only: Set<Double>?, onFrame: (TextTracker.Frame) -> Void) throws {
        let asset = AVURLAsset(url: url)
        guard let track = try loadVideoTrack(asset) else { throw TextFinderError.noVideo }
        var stretches = [(start, end)]
        if let only {
            stretches = []
            for time in only.sorted() where time >= start && time < end {
                if let last = stretches.last, time - last.1 < 1 {
                    stretches[stretches.count - 1].1 = time + 0.001
                } else {
                    stretches.append((time, time + 0.001))
                }
            }
        }
        for (start, end) in stretches {
            try readStretch(asset, track: track, from: start, to: end, pass: pass, texts: texts, only: only, onFrame: onFrame)
        }
    }

    private static func readStretch(_ asset: AVURLAsset, track: AVAssetTrack, from start: Double, to end: Double, pass: Pass,
                                    texts: [String], only: Set<Double>?, onFrame: (TextTracker.Frame) -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        // A little wider than the stretch, since times are rounded to the timescale. The checks below keep to it exactly.
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(start - 0.01, 0), preferredTimescale: 600),
                                       end: CMTime(seconds: end + 0.01, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var lastCareful = -Double.infinity
        var lastCarefulLook = FrameLook()
        var lastCarefulFound: [TextTracker.Found] = []
        var lastQuickLook = FrameLook()
        var lastQuickFound: [TextTracker.Found] = []
        // A worker has no run loop to empty the autorelease pool, so each frame gets its own, or Vision's and the
        // decoder's leftovers pile up until the stretch ends.
        while let sample = output.copyNextSampleBuffer() {
            try autoreleasepool {
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                // A frame showing when a stretch starts belongs to the stretch before.
                guard time >= start, time < end, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                if let only, !only.contains(time) { return }
                // A picture that hasn't visibly changed since a reading reads the same, so that reading is reused. Each frame
                // is compared with the frame that was read, not the one before, so a slow fade can't creep past.
                let look = FrameLook(buffer)
                guard pass == .sampled else {
                    if !look.looksLike(lastCarefulLook) {
                        lastCarefulLook = look
                        lastCarefulFound = try recognize(texts, in: buffer, level: .accurate)
                    }
                    onFrame(TextTracker.Frame(time: time, found: lastCarefulFound, careful: true))
                    return
                }
                if look.looksLike(lastCarefulLook) {
                    onFrame(TextTracker.Frame(time: time, found: lastCarefulFound, careful: true))
                } else if time - lastCareful >= carefulInterval || (time - lastCareful >= changeInterval && look.differsMuch(from: lastCarefulLook)) {
                    lastCareful = time
                    lastCarefulLook = look
                    lastCarefulFound = try recognize(texts, in: buffer, level: .accurate)
                    onFrame(TextTracker.Frame(time: time, found: lastCarefulFound, careful: true))
                } else if look.looksLike(lastQuickLook) {
                    onFrame(TextTracker.Frame(time: time, found: lastQuickFound))
                } else {
                    lastQuickLook = look
                    lastQuickFound = try recognize(texts, in: buffer, level: .fast)
                    onFrame(TextTracker.Frame(time: time, found: lastQuickFound))
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
    }

    private static func loadVideoTrack(_ asset: AVURLAsset) throws -> AVAssetTrack? {
        let loaded = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<AVAssetTrack?, Error> = .success(nil)
        asset.loadTracks(withMediaType: .video) { tracks, error in
            result = error.map { .failure($0) } ?? .success(tracks?.first)
            loaded.signal()
        }
        loaded.wait()
        return try result.get()
    }

    // Each match in the top few readings of each line, so a misreading in the first one doesn't lose the text.
    static func recognize(_ texts: [String], in buffer: CVPixelBuffer, level: VNRequestTextRecognitionLevel) throws -> [TextTracker.Found] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        var found: [TextTracker.Found] = []
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) {
                for text in texts {
                    for (range, missing) in matches(of: text, in: candidate.string) {
                        // Text read without a box of its own gets its whole line's.
                        var box = (try? candidate.boundingBox(for: range))??.boundingBox ?? observation.boundingBox
                        // A reading a character short may have dropped one that's still visible, on either side.
                        if missing > 0 {
                            let character = box.width / Double(max(text.count - missing, 1))
                            box = box.insetBy(dx: -character * Double(missing), dy: 0)
                        }
                        found = TextTracker.merge(found, [.init(text: text, box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width,
                                                                                        height: box.height))])
                    }
                }
            }
        }
        return found
    }

    // Every place `text` appears, ignoring case and look-alikes such as l and 1, plus words of four or more characters one
    // character off, as when the pointer covers a digit. Each comes with how many characters short of the text it is.
    static func matches(of text: String, in line: String) -> [(Range<String.Index>, missing: Int)] {
        let characters = Array(line)
        let indices = Array(line.indices) + [line.endIndex]
        let normal = characters.map(normalized)
        let target = text.map(normalized)
        var result: [(Range<String.Index>, missing: Int)] = []
        var covered: [Range<Int>] = []
        // Text under four characters, such as "MN", matches only where it isn't part of a longer word, or it would cover
        // pieces of words all over the screen. A letter next to a digit still counts as a word's edge.
        func separate(_ start: Int, _ end: Int) -> Bool {
            guard text.count < 4 else { return true }
            func sameKind(_ a: Character, _ b: Character) -> Bool {
                (a.isLetter && b.isLetter) || (a.isNumber && b.isNumber)
            }
            let first = characters[start], last = characters[end - 1]
            return (start == 0 || !sameKind(characters[start - 1], first)) && (end == characters.count || !sameKind(characters[end], last))
        }
        if !target.isEmpty, normal.count >= target.count {
            var i = 0
            while i <= normal.count - target.count {
                if Array(normal[i..<(i + target.count)]) == target, separate(i, i + target.count) {
                    result.append((indices[i]..<indices[i + target.count], 0))
                    covered.append(i..<(i + target.count))
                    i += target.count
                } else {
                    i += 1
                }
            }
        }
        guard text.count >= 4, !text.contains(where: \.isWhitespace) else { return result }
        var i = 0
        while i < characters.count {
            guard characters[i].isLetter || characters[i].isNumber else {
                i += 1
                continue
            }
            var end = i
            while end < characters.count, characters[end].isLetter || characters[end].isNumber {
                end += 1
            }
            let word = Array(normal[i..<end])
            if !covered.contains(where: { $0.overlaps(i..<end) }), abs(word.count - target.count) <= 1, editDistance(word, target) == 1 {
                result.append((indices[i]..<indices[end], max(target.count - word.count, 0)))
            }
            i = end
        }
        return result
    }

    private static func normalized(_ character: Character) -> Character {
        switch character.lowercased().first ?? character {
        case "l", "i", "|": "1"
        case "o": "0"
        case "s": "5"
        case "b": "8"
        case let other: other
        }
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let above = row[j]
                row[j] = Swift.min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = above
            }
        }
        return row[b.count]
    }
}

// A frame's pixels, kept to tell whether a later frame looks the same, and a coarse grid of brightness, to tell whether
// it changed a lot, as when a chat scrolls or a new message arrives.
struct FrameLook {
    private var pixels = Data()
    private var grid: [UInt8] = []

    init() {}

    init(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        pixels = Data(bytes: base, count: rowBytes * height)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<36 {
            for column in 0..<64 {
                let pixel = bytes + (row * height / 36) * rowBytes + (column * width / 64) * 4
                grid.append(UInt8((Int(pixel[0]) + 2 * Int(pixel[1]) + Int(pixel[2])) / 4))
            }
        }
    }

    // No color in any pixel moved by more than `tolerance`, which is about what compression noise reaches. On camp.mp4,
    // about 40% of frames match the last one read, and reusing its reading finds exactly what reading them does.
    func looksLike(_ other: FrameLook, tolerance: Int = 16) -> Bool {
        guard !pixels.isEmpty, pixels.count == other.pixels.count else { return false }
        return pixels.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            other.pixels.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                let a = a.bindMemory(to: UInt8.self), b = b.bindMemory(to: UInt8.self)
                // BGRA, so the fourth byte of each pixel, alpha, is skipped.
                var index = 0
                while index + 2 < a.count {
                    if abs(Int(a[index]) - Int(b[index])) > tolerance || abs(Int(a[index + 1]) - Int(b[index + 1])) > tolerance
                        || abs(Int(a[index + 2]) - Int(b[index + 2])) > tolerance {
                        return false
                    }
                    index += 4
                }
                return true
            }
        }
    }

    // More than one cell in fifty changed clearly. A blinking cursor or a small animation changes a few.
    func differsMuch(from other: FrameLook) -> Bool {
        guard grid.count == other.grid.count else { return true }
        let changed = zip(grid, other.grid).filter { abs(Int($0) - Int($1)) > 24 }.count
        return changed * 50 > grid.count
    }
}

// Adds up progress from the threads reading in parallel, and passes it on only when it has moved, so the main thread
// isn't sent thousands of updates.
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Int: Double] = [:]
    private var last = -1.0
    private let send: @Sendable (Double) -> Void

    init(_ send: @escaping @Sendable (Double) -> Void) {
        self.send = send
    }

    func report(part: Int, of count: Int, fraction: Double) {
        let total: Double? = lock.withLock {
            parts[part] = min(max(fraction, 0), 1)
            let value = parts.values.reduce(0, +) / Double(count)
            guard value - last >= 0.005 else { return nil }
            last = value
            return value
        }
        if let total { send(total) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

// Waits for a worker to exit, whether it exits before or after anyone asks. Says how it ended: "exit 1" or "signal 15".
private final class ExitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var ending: String?
    private var waiting: CheckedContinuation<String, Never>?

    func finish(_ process: Process) {
        let ending = process.terminationReason == .uncaughtSignal ? "signal \(process.terminationStatus)" : "exit \(process.terminationStatus)"
        let waiting: CheckedContinuation<String, Never>? = lock.withLock {
            self.ending = ending
            defer { self.waiting = nil }
            return self.waiting
        }
        waiting?.resume(returning: ending)
    }

    func wait() async -> String {
        await withCheckedContinuation { continuation in
            let ended: String? = lock.withLock {
                if self.ending == nil { self.waiting = continuation }
                return self.ending
            }
            if let ended { continuation.resume(returning: ended) }
        }
    }
}
