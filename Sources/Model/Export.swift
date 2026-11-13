import Foundation

// One combine or compress, made from a snapshot of the session, so the session can be cleared and recorded into while it
// waits or runs. Exports run one at a time, in the order they were started.
@MainActor
@Observable
final class Export: Identifiable {
    enum Status: Equatable {
        case waiting
        case running
        case done(outputBytes: Int64)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let output: URL
    let items: [SessionItem]
    let size: OutputSize
    let quality: Quality
    // The checked Redact Text list when it was started. Empty when nothing is redacted.
    let texts: [String]
    // Joins the clips as they are, which only works when nothing in them needs covering.
    let joins: Bool
    // Which session it came from, so a finished export only shows in that session.
    let session: Int
    var status = Status.waiting
    // What it's doing now, such as "Redacting text in “clip.mov”".
    var stage: String?
    var progress = 0.0
    var startedAt: Date?

    // Running state, kept off the views.
    @ObservationIgnored var run: FFmpegRun?
    @ObservationIgnored var job: EncodeJob?
    @ObservationIgnored var coverStop: CancelFlag?
    @ObservationIgnored let coverPause = PauseGate()
    @ObservationIgnored var coverCopies: [URL] = []
    @ObservationIgnored var cancelled = false
    @ObservationIgnored var activity: NSObjectProtocol?
    @ObservationIgnored var record: HiddenRecord?
    @ObservationIgnored var progressBase = 0.0
    @ObservationIgnored var stageStartedAt = Date()

    init(output: URL, items: [SessionItem], size: OutputSize, quality: Quality, texts: [String], joins: Bool, session: Int) {
        self.output = output
        self.items = items
        self.size = size
        self.quality = quality
        self.texts = texts
        self.joins = joins
        self.session = session
    }

    var name: String { output.lastPathComponent }
    var clips: [Clip] { items.compactMap(\.clip) }
    var duration: Double { items.reduce(0) { $0 + ($1.clip?.duration ?? $1.card?.duration ?? 0) } }
    var isActive: Bool { status == .waiting || status == .running }

    var statusText: String {
        switch status {
        case .waiting: return "Waiting"
        case .running:
            let percent = "\(Int(progress * 100))%"
            var text = (stage.map { "\($0) · " } ?? "") + percent
            if let startedAt, progress > 0.02 {
                let remaining = Date().timeIntervalSince(startedAt) / progress * (1 - progress)
                let minutes = Int((remaining / 60).rounded())
                text += remaining < 60 ? " · under a minute left" : minutes == 1 ? " · about 1 minute left" : " · about \(minutes) minutes left"
            }
            return text
        case let .done(bytes): return "Saved · \(formatBytes(bytes))"
        case let .failed(message): return message
        case .cancelled: return "Canceled"
        }
    }
}

// A line in the export log: what happened and when.
struct LogLine: Identifiable {
    let id = UUID()
    let date: Date
    let text: String

    var formatted: String {
        date.formatted(.dateTime.hour().minute().second()) + "  " + text
    }
}
