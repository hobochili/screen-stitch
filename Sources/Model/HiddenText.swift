import AVFoundation
import CryptoKit
import SwiftUI

// Text to keep out of every video, such as the last four digits of a card. The list is remembered between sessions,
// and an unchecked entry is kept but not hidden.
struct HiddenTextEntry: Codable, Hashable, Identifiable {
    var text: String
    var isOn = true

    var id: String { text }
}

// A covered place in a saved video, in that video's time.
struct HiddenPlace: Codable, Hashable {
    var start: Double
    var end: Double
    var text: String
    var clip: Int
    // When the text was first read, and its box then as a fraction of the saved video's frame from the top left.
    // Videos saved by older versions have neither.
    var at: Double?
    var box: CGRect?
}

// What a saved video hid and where, so it can be checked later.
struct HiddenRecord: Codable, Equatable {
    var texts: [String]
    var places: [HiddenPlace]
}

// Looks for hidden text in one clip and keeps what it found, on disk too, so a relaunch doesn't read the clip again.
@MainActor
@Observable
final class TextSearch {
    // Where found places are kept, by clip file. Tests turn this off.
    nonisolated(unsafe) static var cacheFolder: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Screen Stitch/Redactions", isDirectory: true)
    // Part of the cache's key. It goes up whenever finding or tracking changes, so places found by an older version, which
    // may have missed text, aren't reused.
    static let cacheVersion = 4

    let url: URL
    private let cacheFolder: URL?
    private(set) var found: [String: [TextTrack]] = [:]
    private(set) var progress = 0.0
    private(set) var failure: String?
    @ObservationIgnored private var wanted: Set<String> = []
    @ObservationIgnored private var runner: Task<Void, Never>?
    // Kept apart from `runner` so views showing a spinner are told when the search ends.
    private(set) var isBusy = false
    @ObservationIgnored private var control = SearchControl()
    // The file's size and date when `found` was read or made.
    @ObservationIgnored private var stamp: String?

    init(url: URL, cacheFolder: URL? = TextSearch.cacheFolder) {
        self.url = url
        self.cacheFolder = cacheFolder
        stamp = Self.stamp(of: url)
        loadCache()
    }

    func look(for texts: [String]) {
        checkFile()
        wanted = Set(texts)
        failure = nil
        if runner == nil, !wanted.subtracting(found.keys).isEmpty {
            control = SearchControl()
            isBusy = true
            runner = Task { await run() }
        }
    }

    // Forgets what was found if the file has changed since, as when a recording is replaced at the same path.
    func checkFile() {
        let current = Self.stamp(of: url)
        guard current != stamp else { return }
        control.stop()
        stamp = current
        found = [:]
        loadCache()
    }

    func finished() async {
        await runner?.value
    }

    func cancel() {
        control.stop()
    }

    // Moves its workers into the background band, or back out.
    func setBackground(_ background: Bool) {
        control.setBackground(background)
    }

    func forgetFailure() {
        failure = nil
    }

    private func run() async {
        let control = control
        while failure == nil, !control.isStopped {
            let missing = wanted.subtracting(found.keys).sorted()
            guard !missing.isEmpty else { break }
            progress = 0
            let searched = stamp
            do {
                let result = try await TextFinder.find(missing, in: url, progress: { value in
                    Task { @MainActor in self.progress = value }
                }, control: control)
                // A file replaced during the search was stopped by `checkFile`, and these results are for the old one.
                guard !control.isStopped, stamp == searched else { break }
                for text in missing {
                    found[text] = result[text] ?? []
                }
                saveCache()
            } catch is CancellationError {
                break
            } catch {
                failure = error.localizedDescription
            }
        }
        runner = nil
        isBusy = false
    }

    private static func stamp(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return "\(size)|\(date.timeIntervalSince1970)"
    }

    private var cacheFile: URL? {
        guard let folder = cacheFolder, let stamp else { return nil }
        let key = SHA256.hash(data: Data("\(Self.cacheVersion)|\(url.path)|\(stamp)".utf8))
        return folder.appendingPathComponent(key.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    private func loadCache() {
        if let file = cacheFile, let data = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode([String: [TextTrack]].self, from: data) {
            found = cached
        }
    }

    private func saveCache() {
        guard let file = cacheFile, let data = try? JSONEncoder().encode(found) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

// The Check Redactions sheet: the saved video, which place is showing, and a picture of each.
@MainActor
@Observable
final class HiddenTextReview: Identifiable {
    let id = UUID()
    let video: URL
    let record: HiddenRecord
    let player: AVPlayer
    private(set) var current: Int?
    // Each place's box with some of the picture around it, as it looks in the saved video.
    private(set) var thumbnails: [Int: NSImage] = [:]
    // Whether the player is paused on the current place's first reading, where its box is outlined.
    private(set) var isOnPlace = false
    var showsHelp = false
    @ObservationIgnored private var endObserver: Any?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?

    init(video: URL, record: HiddenRecord) {
        self.video = video
        self.record = record
        player = AVPlayer(url: video)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIsOnPlace() }
        }
        thumbnailTask = Task { [weak self] in await self?.makeThumbnails() }
    }

    var places: [HiddenPlace] { record.places }

    var outline: CGRect? {
        guard isOnPlace, let current else { return nil }
        return places[current].box
    }

    // Stops on the moment the text was first read, with its box outlined. Places saved without one play from a second
    // before instead. Either way, playing stops just after the place.
    func show(_ index: Int) {
        guard places.indices.contains(index) else { return }
        current = index
        let place = places[index]
        if let endObserver {
            player.removeTimeObserver(endObserver)
        }
        endObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: place.end + 0.3, preferredTimescale: 600))],
                                                     queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.player.pause() }
        }
        if let at = place.at {
            player.pause()
            player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.updateIsOnPlace() }
            }
        } else {
            player.seek(to: CMTime(seconds: max(place.start - 1, 0), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
                [weak self] finished in
                guard finished else { return }
                Task { @MainActor in self?.player.play() }
            }
        }
    }

    func step(_ offset: Int) {
        guard !places.isEmpty else { return }
        show(min(max((current ?? -1) + offset, 0), places.count - 1))
    }

    func close() {
        player.pause()
        thumbnailTask?.cancel()
        for observer in [endObserver, timeObserver].compactMap({ $0 }) {
            player.removeTimeObserver(observer)
        }
        endObserver = nil
        timeObserver = nil
    }

    private func updateIsOnPlace() {
        guard let current, let at = places[current].at else {
            isOnPlace = false
            return
        }
        isOnPlace = player.rate == 0 && abs(player.currentTime().seconds - at) < 0.05
    }

    private func makeThumbnails() async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        for (index, place) in places.enumerated() {
            guard !Task.isCancelled, let at = place.at, let box = place.box,
                  let image = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image else { continue }
            thumbnails[index] = NSImage(cgImage: Self.crop(image, around: box), size: .zero)
        }
    }

    // A strip three times as wide as it's tall, centered on the box, with room around it to see what's next to it.
    nonisolated static func crop(_ image: CGImage, around box: CGRect) -> CGImage {
        let width = Double(image.width), height = Double(image.height)
        let rect = CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height)
        var cropHeight = rect.height * 3
        var cropWidth = max(cropHeight * 3, rect.width * 1.4)
        cropHeight = max(cropHeight, cropWidth / 3)
        cropWidth = min(cropWidth, width)
        cropHeight = min(cropHeight, height)
        let x = min(max(rect.midX - cropWidth / 2, 0), width - cropWidth)
        let y = min(max(rect.midY - cropHeight / 2, 0), height - cropHeight)
        return image.cropping(to: CGRect(x: x, y: y, width: cropWidth, height: cropHeight).integral) ?? image
    }
}

extension StitchModel {
    // Covered copies and frame lists left in the temporary folder by a crash. Only old ones go, since another copy of
    // Screen Stitch may be using newer ones.
    nonisolated static func removeLeftoverRedactionFiles() {
        let folder = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("screen-stitch-covered-") || name.hasPrefix("screen-stitch-times-") {
            let file = folder.appendingPathComponent(name)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < Date().addingTimeInterval(-3600) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    var activeHiddenText: [String] {
        redactsText ? hiddenText.filter(\.isOn).map(\.text) : []
    }

    func clearHiddenText() {
        hiddenText = []
    }

    // Adds each line as its own entry. Returns why nothing was added, if it wasn't.
    @discardableResult
    func addHiddenText(_ input: String) -> String? {
        let lines = input.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let usable = lines.filter { $0.count >= 2 }
        guard !usable.isEmpty else { return lines.isEmpty ? nil : "Type at least 2 characters." }
        for text in usable {
            if let index = hiddenText.firstIndex(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
                hiddenText[index].isOn = true
            } else {
                hiddenText.append(HiddenTextEntry(text: text))
            }
        }
        return nil
    }

    func removeHiddenText(_ text: String) {
        hiddenText.removeAll { $0.text == text }
    }

    func setHiddenText(_ text: String, isOn: Bool) {
        guard let index = hiddenText.firstIndex(where: { $0.text == text }) else { return }
        hiddenText[index].isOn = isOn
    }

    func search(for url: URL) -> TextSearch {
        if let search = textSearches[url] { return search }
        let search = TextSearch(url: url)
        textSearches[url] = search
        return search
    }

    // Whether a clip still has text to look for. A clip that couldn't be read is tried again only when the list changes
    // or the session is combined.
    func needsSearch(_ clip: Clip, for texts: [String]? = nil) -> Bool {
        let search = textSearches[clip.url]
        guard search?.failure == nil else { return false }
        return (texts ?? activeHiddenText).contains { search?.found[$0] == nil }
    }

    var failedSearchClip: Clip? {
        clips.first { textSearches[$0.url]?.failure != nil }
    }

    var searchingClip: Clip? {
        clips.first { textSearches[$0.url]?.isBusy == true }
    }

    // Searches one clip at a time: the unfinished exports' clips first, in the order they were started, then the
    // session's. While recording, searches and FFmpeg carry on in the background band and redacting waits, so capture
    // keeps the processors and video encoder it needs.
    func updateSearches() {
        var wanted: [(clip: Clip, texts: [String])] = []
        for export in exports where export.isActive && !export.texts.isEmpty && !export.joins {
            wanted += export.clips.map { ($0, export.texts) }
        }
        if !activeHiddenText.isEmpty {
            wanted += clips.map { ($0, activeHiddenText) }
        }
        let urls = Set(wanted.map(\.clip.url))
        for (url, search) in textSearches where search.isBusy && !urls.contains(url) {
            search.cancel()
        }
        let background = recording.isCapturing
        textSearches.values.forEach { $0.setBackground(background) }
        runningExport?.run?.setBackground(background)
        runningExport?.coverPause.set(background)
        guard !textSearches.values.contains(where: \.isBusy),
              let next = wanted.first(where: { needsSearch($0.clip, for: $0.texts) })?.clip else { return }
        // Everything any list wants from the clip, so it isn't read again for another.
        let texts = Array(Set(wanted.filter { $0.clip.url == next.url }.flatMap(\.texts))).sorted()
        let search = search(for: next.url)
        search.look(for: texts)
        search.setBackground(background)
        let started = Date()
        log("Looking for text in “\(next.name)” (\(formatDuration(next.duration)) long)")
        Task {
            await search.finished()
            let took = formatDuration(Date().timeIntervalSince(started))
            if let failure = search.failure {
                warning = "Couldn't look for text in “\(next.name)”. \(failure)"
                log("Couldn't look for text in “\(next.name)” after \(took): \(failure)")
            } else {
                let places = texts.reduce(0) { $0 + Self.places(of: search.found[$1] ?? [], duration: next.duration).count }
                log("Looked through “\(next.name)” in \(took): \(places == 1 ? "1 place" : "\(places) places") found")
            }
            updateSearches()
        }
    }

    // Where a clip's checked text was found, once all of it has been looked for.
    func hiddenTextTracks(for clip: Clip, texts: [String]? = nil) -> [TextTrack]? {
        let texts = texts ?? activeHiddenText
        guard let search = textSearches[clip.url] else { return texts.isEmpty ? [] : nil }
        var tracks: [TextTrack] = []
        for text in texts {
            guard let found = search.found[text] else { return nil }
            tracks += found
        }
        return tracks
    }

    // The stretches of a clip where its checked text shows.
    func hiddenPlaces(in clip: Clip) -> [ClosedRange<Double>] {
        guard let search = textSearches[clip.url] else { return [] }
        return activeHiddenText.flatMap { Self.places(of: search.found[$0] ?? [], duration: clip.duration) }
    }

    // "Redacts “9611” in 3 places", for a clip's row.
    func hiddenTooltip(for clip: Clip) -> String {
        let search = textSearches[clip.url]
        let parts = activeHiddenText.compactMap { text -> String? in
            let count = Self.places(of: search?.found[text] ?? [], duration: clip.duration).count
            return count == 0 ? nil : "“\(text)” in \(count == 1 ? "1 place" : "\(count) places")"
        }
        return "Redacts " + parts.formatted(.list(type: .and))
    }

    // How often one entry was found across the clips, or nil before there's anything to say.
    func hiddenTextStatus(_ entry: HiddenTextEntry) -> String? {
        guard redactsText, entry.isOn, !clips.isEmpty else { return nil }
        if clips.contains(where: { textSearches[$0.url]?.found[entry.text] == nil && textSearches[$0.url]?.failure == nil }) {
            return "Looking…"
        }
        if let failed = failedSearchClip {
            return "Couldn't search “\(failed.name)”"
        }
        let counts = clips.map { Self.places(of: textSearches[$0.url]?.found[entry.text] ?? [], duration: $0.duration).count }
        let total = counts.reduce(0, +)
        let inClips = counts.filter { $0 > 0 }.count
        switch total {
        case 0: return clips.count == 1 ? "Not found in this clip" : "Not found in these clips"
        case 1: return "Found in 1 place"
        case 26...: return "Found in \(total) places. Check it isn't redacting more than you want."
        default:
            guard clips.count > 1 else { return "Found in \(total) places" }
            let inWhich: String = inClips == 1 ? "1 clip" : "\(inClips) clips"
            return "Found in \(total) places in \(inWhich)"
        }
    }

    // The bottom bar's line: what's hidden, then what the search is doing or found.
    var hidingLine: String? {
        let texts = activeHiddenText
        guard !texts.isEmpty else { return nil }
        let names: String = texts.count > 3 ? "\(texts.prefix(2).joined(separator: ", ")), and \(texts.count - 2) more"
            : texts.formatted(.list(type: .and))
        var line = "Redacting \(names)"
        guard !clips.isEmpty else { return line }
        if let clip = searchingClip ?? clips.first(where: { needsSearch($0) }), let index = clips.firstIndex(of: clip) {
            line += clips.count == 1 ? " · Looking through the clip…" : " · Looking through clip \(index + 1) of \(clips.count)…"
            return line + (recording.isCapturing ? " · Slower while recording" : "")
        }
        if let failed = failedSearchClip {
            return line + " · Couldn't search “\(failed.name)”"
        }
        let total = clips.reduce(0) { $0 + hiddenPlaces(in: $1).count }
        guard total > 0 else { return line + (clips.count == 1 ? " · Not found in this clip" : " · Not found in these clips") }
        line += total == 1 ? " · Found in 1 place" : " · Found in \(total) places"
        let missing = texts.filter { text in clips.allSatisfy { (textSearches[$0.url]?.found[text] ?? []).isEmpty } }
        if !missing.isEmpty {
            line += " · \(missing.formatted(.list(type: .and))) not found"
        }
        return line
    }

    func checkHiddenText(in video: URL) {
        guard let record = hiddenRecords[video.standardizedFileURL] else { return }
        let review = HiddenTextReview(video: video, record: record)
        hiddenTextReview = review
        checkedVideos.insert(video.standardizedFileURL)
        review.step(1)
    }

    func closeHiddenTextReview() {
        hiddenTextReview?.close()
        hiddenTextReview = nil
    }

    func hiddenRecord(for video: URL) -> HiddenRecord? {
        hiddenRecords[video.standardizedFileURL]
    }

    // The saved-video caption: what was hidden and how often.
    // Only the text that was found is named as hidden. The rest is named as not found.
    func hiddenSummary(for video: URL) -> String? {
        guard let record = hiddenRecord(for: video), !record.texts.isEmpty else { return nil }
        let found = record.texts.filter { text in record.places.contains { $0.text == text } }
        let missing = record.texts.filter { !found.contains($0) }
        let missingNames = missing.formatted(.list(type: .and))
        let notFound = missing.count == 1 ? "\(missingNames) wasn't found." : "\(missingNames) weren't found."
        guard !found.isEmpty else { return "Nothing was redacted. " + notFound }
        let count = record.places.count
        var summary = "\(found.formatted(.list(type: .and))) redacted in \(count == 1 ? "1 place" : "\(count) places")."
        if !missing.isEmpty {
            summary += " " + notFound
        }
        return summary + (count == 1 ? " Check it before you share." : " Check them before you share.")
    }

    // Text checked since the video was made, which it doesn't hide.
    func staleNote(for video: URL) -> String? {
        let hidden = Set(hiddenRecord(for: video)?.texts ?? [])
        let added = activeHiddenText.filter { !hidden.contains($0) }
        guard !added.isEmpty else { return nil }
        let names = added.map { "“\($0)”" }.formatted(.list(type: .and))
        return added.count == 1 ? "This video doesn't redact \(names). Combine again to redact it."
            : "This video doesn't redact \(names). Combine again to redact them."
    }

    // Where each clip's tracks land in the combined video, given the clips and title cards before it.
    func hiddenRecord(items: [SessionItem], texts: [String], tracks: [UUID: [TextTrack]], size: OutputSize) -> HiddenRecord {
        var places: [HiddenPlace] = []
        var offset = 0.0
        var number = 0
        let clips = items.compactMap { if case let .clip(clip) = $0 { clip } else { nil } }
        let (width, height, scale) = EncodeJob.canvas(for: clips, size: size)
        for item in items {
            switch item {
            case let .clip(clip):
                number += 1
                // Each clip is scaled by the same amount and centered in the video, as EncodeJob does.
                let clipWidth = Double(clip.width) * scale, clipHeight = Double(clip.height) * scale
                let left = (Double(width) - clipWidth) / 2, top = (Double(height) - clipHeight) / 2
                for text in texts {
                    for (range, track) in Self.spots(of: (tracks[clip.id] ?? []).filter { $0.text == text }, duration: clip.duration) {
                        let first = track.sightings[0]
                        let box = CGRect(x: (left + first.box.minX * clipWidth) / Double(width),
                                         y: (top + first.box.minY * clipHeight) / Double(height),
                                         width: first.box.width * clipWidth / Double(width),
                                         height: first.box.height * clipHeight / Double(height))
                        places.append(HiddenPlace(start: offset + range.lowerBound, end: offset + range.upperBound, text: text, clip: number,
                                                  at: offset + first.time, box: box))
                    }
                }
                offset += clip.duration
            case let .card(card):
                offset += card.duration
            }
        }
        return HiddenRecord(texts: texts, places: places.sorted { ($0.at ?? $0.start) < ($1.at ?? $1.start) })
    }

    // The stretches of a clip where a piece of text shows, one for each spot on screen it was covered.
    static func places(of tracks: [TextTrack], duration: Double) -> [ClosedRange<Double>] {
        spots(of: tracks, duration: duration).map(\.range)
    }

    static func spots(of tracks: [TextTrack], duration: Double) -> [(range: ClosedRange<Double>, track: TextTrack)] {
        tracks.compactMap { track in
            let start = max(0, track.start), end = min(duration, track.end)
            return start <= end ? (start...end, track) : nil
        }
        .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
