import Foundation

// The session as it's kept on disk between launches: where each clip is, the title cards, and which files the session
// made. Clips are probed again on launch, since a file may have changed or gone in the meantime.
struct SavedSession: Codable, Equatable {
    enum Item: Codable, Equatable {
        case clip(URL)
        case card(text: String, duration: Double, isLight: Bool, role: TitleCard.Role?)
    }

    var items: [Item]
    var isManuallyOrdered: Bool
    var recordings: [URL]
    var outputs: [URL]
    // What each saved video hid, by its path.
    var hiddenRecords: [String: HiddenRecord]? = nil

    nonisolated(unsafe) static var defaultFile: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Screen Stitch/session.json")

    static func load(from file: URL) -> SavedSession? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SavedSession.self, from: $0) }
    }

    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
