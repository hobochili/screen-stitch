import Foundation

struct Clip: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let date: Date
    let duration: Double
    let width: Int
    let height: Int
    let videoStream: Int
    let audioStreams: Int
    let fileSize: Int64
    // Codec, size and encoder settings of every track. Clips with the same one can be joined without re-encoding; nil
    // when a track can't go in an MP4 as is.
    var copyFormat: String? = nil

    var name: String { url.lastPathComponent }

    static func chronological(_ a: Clip, _ b: Clip) -> Bool {
        a.date != b.date ? a.date < b.date : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

// Text shown full-frame between clips in the combined video, such as "Before…" and "After…".
struct TitleCard: Identifiable, Hashable {
    static let durations: ClosedRange<Double> = 0.25...10

    enum Role {
        case before
        case after
    }

    let id = UUID()
    var text: String
    var duration: Double = 1.25
    // Black text on white instead of white on black.
    var isLight = false
    // Set on the cards Before & After adds, so turning it off removes just those.
    var role: Role?
}

// A row in the session: a clip, or a title card that goes between clips.
enum SessionItem: Identifiable, Hashable {
    case clip(Clip)
    case card(TitleCard)

    var id: UUID {
        switch self {
        case let .clip(clip): clip.id
        case let .card(card): card.id
        }
    }

    var clip: Clip? {
        if case let .clip(clip) = self { clip } else { nil }
    }

    var card: TitleCard? {
        if case let .card(card) = self { card } else { nil }
    }
}

enum OutputSize: Int, CaseIterable, Identifiable {
    case original = 0
    case p1440 = 1440
    case p1080 = 1080
    case p720 = 720

    var id: Int { rawValue }
    var label: String { self == .original ? "Original" : "\(rawValue)p" }

    init?(argument: String) {
        let value = argument.lowercased()
        if value == "original" {
            self = .original
        } else if let height = Int(value.hasSuffix("p") ? String(value.dropLast()) : value), let size = OutputSize(rawValue: height) {
            self = size
        } else {
            return nil
        }
    }
}

enum Quality: String, CaseIterable, Identifiable {
    case high = "High"
    case standard = "Standard"
    case small = "Smaller File"

    var id: String { rawValue }

    init?(argument: String) {
        switch argument.lowercased() {
        case "high": self = .high
        case "standard": self = .standard
        case "small": self = .small
        default: return nil
        }
    }

    var crf: Int {
        switch self {
        case .high: 20
        case .standard: 23
        case .small: 28
        }
    }
}
