import Foundation
import Testing

@Suite struct FormattingTests {
    @Test(arguments: [(0.0, "0:00"), (59.4, "0:59"), (59.6, "1:00"), (3599, "59:59"), (3600, "1:00:00"),
                      (3725, "1:02:05")])
    func durations(seconds: Double, text: String) {
        #expect(formatDuration(seconds) == text)
    }

    @Test func foldersInHomeReadLikeFinder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(displayPath(home.appendingPathComponent("Movies/Screen Stitch")) == "Movies › Screen Stitch")
    }

    @Test func homeItselfIsATilde() {
        #expect(displayPath(FileManager.default.homeDirectoryForCurrentUser) == "~")
    }

    @Test func foldersOutsideHomeStartAtTheTop() {
        #expect(displayPath(URL(fileURLWithPath: "/Volumes/Backup/Clips")) == "Volumes › Backup › Clips")
    }
}

@Suite struct OrderTests {
    @Test func earlierRecordingsComeFirst() {
        let early = makeClip("b.mov", date: Date(timeIntervalSince1970: 100))
        let late = makeClip("a.mov", date: Date(timeIntervalSince1970: 200))
        #expect([late, early].sorted(by: Clip.chronological).map(\.name) == ["b.mov", "a.mov"])
    }

    // Finder order, so "Clip 2" comes before "Clip 10".
    @Test func sameTimeFallsBackToTheName() {
        let names = ["Clip 10.mov", "Clip 2.mov", "Clip 1.mov"]
        #expect(names.map { makeClip($0) }.sorted(by: Clip.chronological).map(\.name) == ["Clip 1.mov", "Clip 2.mov", "Clip 10.mov"])
    }
}
