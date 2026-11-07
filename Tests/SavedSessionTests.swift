import Foundation
import Testing

@MainActor
@Suite(.enabled(if: tools != nil, "needs FFmpeg"))
struct SavedSessionTests {
    private func model(saving file: URL) -> StitchModel {
        let model = StitchModel()
        model.useGlobalShortcuts = false
        model.sessionFile = file
        return model
    }

    private func probe(_ url: URL) throws -> SessionItem {
        .clip(try Prober.probe(url, ffprobe: tools!.ffprobe))
    }

    @Test func relaunchBringsBackTheListCardsAndFiles() async throws {
        let folder = try TemporaryFolder()
        let first = folder.file("first.mov")
        let second = folder.file("second.mov")
        try makeVideo(first, width: 320, height: 240)
        try makeVideo(second, width: 320, height: 240)
        let file = folder.file("session.json")
        let before = model(saving: file)
        before.items = [try probe(first), try probe(second)]
        before.toggleBeforeAndAfter()
        before.move(from: [3], to: 1)
        before.updateCard(before.titleCards[1].id) { $0.isLight = true }
        before.sessionRecordings = [first]
        before.sessionOutputs = [folder.file("combined.mp4")]
        before.saveSession()

        let after = model(saving: file)
        await after.restoreSession()
        let rows = after.items.map { item in
            switch item {
            case let .clip(clip): clip.name
            case let .card(card): "\(card.text) \(card.isLight ? "light" : "dark") \(card.role.map { "\($0)" } ?? "")"
            }
        }
        #expect(rows == ["Before… dark before", "second.mov", "first.mov", "After… light after"])
        #expect(!after.isDateOrdered)
        #expect(after.hasBeforeAndAfter)
        #expect(after.sessionRecordings == [first])
        #expect(after.sessionOutputs == [folder.file("combined.mp4")])
        #expect(after.warning == nil)
    }

    @Test func clipsGoneSinceLastTimeAreLeftOutAndNamed() async throws {
        let folder = try TemporaryFolder()
        let kept = folder.file("kept.mov")
        let gone = folder.file("gone.mov")
        try makeVideo(kept, width: 320, height: 240)
        try makeVideo(gone, width: 320, height: 240)
        let file = folder.file("session.json")
        let before = model(saving: file)
        before.items = [try probe(kept), try probe(gone)]
        before.saveSession()
        try FileManager.default.removeItem(at: gone)

        let after = model(saving: file)
        await after.restoreSession()
        #expect(after.clips.map(\.name) == ["kept.mov"])
        #expect(after.warning == "Left out (moved, deleted or can't be opened since last time): gone.mov")
        // The file now matches what's in the list.
        #expect(SavedSession.load(from: file)?.items == [.clip(kept)])
    }

    @Test func videosOpenedDuringLaunchGoAfterTheSavedOnes() async throws {
        let folder = try TemporaryFolder()
        let saved = folder.file("saved.mov")
        let opened = folder.file("opened.mov")
        try makeVideo(saved, width: 320, height: 240)
        try makeVideo(opened, width: 320, height: 240)
        let file = folder.file("session.json")
        let before = model(saving: file)
        before.items = [try probe(saved)]
        before.move(from: [0], to: 1)
        before.saveSession()

        let after = model(saving: file)
        after.items = [try probe(opened)]
        await after.restoreSession()
        #expect(after.clips.map(\.name) == ["saved.mov", "opened.mov"])
    }

    @Test func changesAreSavedAfterTheCurrentEvent() async throws {
        let folder = try TemporaryFolder()
        let file = folder.file("session.json")
        let model = model(saving: file)
        model.addTitleCard()
        model.updateCard(model.titleCards[0].id) { $0.text = "Hello" }
        #expect(SavedSession.load(from: file) == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(SavedSession.load(from: file)?.items == [.card(text: "Hello", duration: 1.25, isLight: false, role: nil)])
    }
}
