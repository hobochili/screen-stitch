import AppKit
import Testing

@MainActor
@Suite struct RemovalTests {
    private let folder: TemporaryFolder
    private let trash: URL
    private let model = StitchModel()

    // Clips with real files, and a stand-in Trash folder they're moved into.
    init() throws {
        folder = try TemporaryFolder()
        trash = folder.file("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trash = trash
        model.moveToTrash = { url in
            let inTrash = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: inTrash)
            return inTrash
        }
    }

    private func addClips(_ names: [String], recorded: Bool = true) throws {
        for name in names {
            let url = folder.file(name)
            try Data().write(to: url)
            model.items.append(.clip(Clip(url: url, date: Date(), duration: 1, width: 2, height: 2, videoStream: 0,
                                          audioStreams: 0, fileSize: 0)))
            if recorded {
                model.sessionRecordings.insert(url)
            }
        }
    }

    private var names: [String] {
        model.items.map { $0.clip?.name ?? "card" }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.file(name).path)
    }

    @Test func removingLeavesTheFileAndUndoBringsTheRowBack() throws {
        try addClips(["1.mov", "2.mov", "3.mov"])
        model.selection = [model.clips[1].id]
        model.remove([model.clips[1].id])
        #expect(names == ["1.mov", "3.mov"])
        #expect(exists("2.mov"))
        #expect(model.notice == "Removed “2.mov” from the list.")
        #expect(model.canTrashRemoved)
        model.undoRemoval()
        #expect(names == ["1.mov", "2.mov", "3.mov"])
        #expect(model.selection == [model.clips[1].id])
        #expect(model.notice == nil && model.removal == nil)
    }

    @Test func noticeDescribesWhatWasRemoved() throws {
        try addClips(["1.mov", "2.mov", "3.mov"])
        model.addTitleCard()
        model.remove(Set(model.items.map(\.id)))
        #expect(model.notice == "Removed 3 clips and 1 title card from the list.")
        model.undoRemoval()
        model.remove([model.titleCards[0].id])
        #expect(model.notice == "Removed the “Title” title card from the list.")
        #expect(!model.canTrashRemoved)
    }

    @Test func anotherChangeEndsTheUndo() throws {
        try addClips(["1.mov", "2.mov"])
        model.remove([model.clips[0].id])
        model.addTitleCard()
        #expect(model.removal == nil && model.notice == nil)
    }

    @Test func removedRecordingsCanStillGoToTheTrashAndComeBack() throws {
        try addClips(["1.mov", "2.mov"])
        model.remove([model.clips[0].id])
        model.trashRemoved()
        #expect(!exists("1.mov"))
        #expect(model.notice == "Moved “1.mov” to the Trash.")
        model.putBack()
        #expect(exists("1.mov"))
        #expect(names == ["1.mov", "2.mov"])
    }

    @Test func videosAddedFromElsewhereCantBeTrashedFromTheNotice() throws {
        try addClips(["mine.mov"])
        try addClips(["theirs.mov"], recorded: false)
        model.remove(Set(model.clips.map(\.id)))
        #expect(!model.canTrashRemoved)
    }

    @Test func trashingTakesCardsChosenWithTheClips() throws {
        try addClips(["1.mov", "2.mov"])
        model.selection = [model.clips[0].id]
        model.addTitleCard()
        model.trash(Set(model.items.prefix(2).map(\.id)))
        #expect(names == ["2.mov"])
        #expect(!exists("1.mov"))
        #expect(model.notice == "Moved “1.mov” to the Trash.")
        #expect(model.selection == [model.clips[0].id])
        model.putBack()
        #expect(names == ["1.mov", "card", "2.mov"])
    }

    @Test func aClipThatCantBeTrashedStays() throws {
        try addClips(["1.mov", "locked.mov"])
        model.moveToTrash = { url in
            if url.lastPathComponent == "locked.mov" { throw CocoaError(.fileWriteNoPermission) }
            return nil
        }
        model.trash(Set(model.clips.map(\.id)))
        #expect(names == ["locked.mov"])
        #expect(model.warning == "Couldn't move to the Trash: locked.mov")
        // Without knowing where the file went, there's nothing to put back.
        #expect(model.notice == "Moved “1.mov” to the Trash." && model.removal == nil)
    }

    @Test func onlyVideosFromElsewhereAskFirst() throws {
        try addClips(["mine.mov", "also mine.mov"])
        try addClips(["theirs.mov"], recorded: false)
        let ids = model.clips.map(\.id)
        #expect(model.trashPrompt(for: Set(ids.prefix(2))) == nil)
        #expect(model.trashPrompt(for: [ids[2]])?.title == "Move “theirs.mov” to the Trash?")
        let mixed = model.trashPrompt(for: Set(ids))
        #expect(mixed?.title == "Move 3 clips to the Trash?")
        #expect(mixed?.message.hasPrefix("1 of the 3 clips was added from elsewhere. Screen Stitch didn't record it.") == true)
    }

    @Test func aRowsMenuActsOnTheSelectionItsPartOf() throws {
        try addClips(["1.mov", "2.mov", "3.mov"])
        let ids = model.clips.map(\.id)
        model.selection = [ids[0], ids[1]]
        #expect(model.targets(for: ids[1]) == [ids[0], ids[1]])
        #expect(model.targets(for: ids[2]) == [ids[2]])
    }

    @Test func savedLineReplacesTheCardOnceTheListChanges() throws {
        try addClips(["1.mov", "2.mov"])
        let first = folder.file("first.mp4")
        let second = folder.file("second.mp4")
        try Data().write(to: first)
        try Data().write(to: second)
        model.sessionOutputs = [first, second]
        model.state = .done(output: second, outputBytes: 1, inputBytes: 2)
        #expect(!model.showsSavedLine)
        model.remove([model.clips[0].id])
        #expect(model.showsSavedLine)
        #expect(model.savedVideos == [second, first])
        #expect(model.shownSavedVideo == second)
        model.shownVideo = first
        #expect(model.shownSavedVideo == first)
        // A video deleted in the Finder drops out.
        try FileManager.default.removeItem(at: first)
        #expect(model.shownSavedVideo == second)
        try FileManager.default.removeItem(at: second)
        #expect(!model.showsSavedLine)
    }

    @Test func clearingWithOnlySavedVideosOffersToTrashThem() throws {
        let video = folder.file("Demo combined.mp4")
        try Data().write(to: video)
        model.sessionOutputs = [video]
        #expect(model.hasBottomBar)
        let prompt = model.clearPrompt
        #expect(prompt.choices.map(\.label) == ["Keep Files", "Move Video to Trash"])
        #expect(prompt.message.contains("“Demo combined.mp4”"))
        model.clearSession(.moveEverything)
        #expect(!FileManager.default.fileExists(atPath: video.path))
        #expect(!model.hasBottomBar || model.notice != nil)
    }
}
