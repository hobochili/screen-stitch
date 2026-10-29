import AppKit
import Testing

@MainActor
@Suite struct SessionTests {
    private func session(_ count: Int) -> StitchModel {
        let model = StitchModel()
        model.items = (1...count).map { .clip(makeClip("Clip \($0).mov")) }
        return model
    }

    private func names(_ urls: [URL]) -> [String] {
        urls.map(\.lastPathComponent)
    }

    @Test func quickLookShowsTheSelectionInListOrder() {
        let model = session(3)
        model.selection = [model.clips[2].id, model.clips[0].id]
        #expect(names(model.quickLookItems) == ["Clip 1.mov", "Clip 3.mov"])
    }

    @Test func arrowsMoveTheSelectionAndStopAtTheEnds() {
        let model = session(3)
        model.selection = [model.clips[0].id]
        model.moveSelection(by: -1)
        #expect(names(model.quickLookItems) == ["Clip 1.mov"])
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        #expect(names(model.quickLookItems) == ["Clip 3.mov"])
    }

    @Test func arrowsFromSeveralSelectedClipsStartAtTheEdge() {
        let model = session(4)
        model.selection = [model.clips[1].id, model.clips[2].id]
        model.moveSelection(by: 1)
        #expect(names(model.quickLookItems) == ["Clip 4.mov"])
        model.selection = [model.clips[1].id, model.clips[2].id]
        model.moveSelection(by: -1)
        #expect(names(model.quickLookItems) == ["Clip 1.mov"])
    }

    @Test func removedClipsLeaveTheSelection() {
        let model = session(3)
        model.selection = [model.clips[1].id]
        model.remove(model.clips[1])
        #expect(model.selection.isEmpty)
    }

    @Test func keepingFilesEmptiesTheSessionAndTrashesNothing() {
        let model = session(2)
        var trashed: [URL] = []
        model.moveToTrash = { trashed.append($0) }
        model.state = .done(output: URL(fileURLWithPath: "/tmp/out.mp4"), outputBytes: 1, inputBytes: 2)
        model.outputThumbnail = NSImage(size: CGSize(width: 16, height: 9))
        model.clearSession(.keepFiles)
        #expect(model.clips.isEmpty)
        #expect(model.state == .idle)
        #expect(model.outputThumbnail == nil)
        #expect(trashed.isEmpty)
    }

    @Test func movingClipsLeavesTheCombinedVideo() throws {
        let folder = try TemporaryFolder()
        let output = folder.file("combined.mp4")
        try Data().write(to: output)
        let model = session(2)
        model.sessionOutputs = [output]
        var trashed: [URL] = []
        model.moveToTrash = { trashed.append($0) }
        model.clearSession(.moveClips)
        #expect(names(trashed) == ["Clip 1.mov", "Clip 2.mov"])
        #expect(model.clips.isEmpty)
    }

    @Test func movingEverythingAlsoMovesTheCombinedVideos() throws {
        let folder = try TemporaryFolder()
        let first = folder.file("first.mp4")
        let second = folder.file("second.mp4")
        try Data().write(to: first)
        try Data().write(to: second)
        let model = session(1)
        model.sessionOutputs = [first, second, folder.file("deleted since.mp4")]
        var trashed: [URL] = []
        model.moveToTrash = { trashed.append($0) }
        model.clearSession(.moveEverything)
        #expect(names(trashed) == ["Clip 1.mov", "first.mp4", "second.mp4"])
    }

    @Test func filesThatCantBeTrashedAreNamed() {
        let model = session(2)
        model.moveToTrash = { url in
            if url.lastPathComponent == "Clip 2.mov" { throw CocoaError(.fileWriteNoPermission) }
        }
        model.clearSession(.moveClips)
        #expect(model.warning == "Couldn't move to the Trash: Clip 2.mov")
        #expect(model.notice == "Moved 1 file to the Trash.")
        #expect(model.clips.isEmpty)
    }

    @Test func promptSaysWhatEachChoiceMoves() throws {
        let folder = try TemporaryFolder()
        let output = folder.file("Demo combined.mp4")
        try Data().write(to: output)
        let model = session(4)
        model.sessionRecordings = Set(model.clips.prefix(2).map(\.url))
        model.sessionOutputs = [output]
        model.state = .done(output: output, outputBytes: 1, inputBytes: 2)
        let prompt = model.clearPrompt
        #expect(prompt.offersEverything)
        #expect(prompt.title == "Clear this session?")
        #expect(prompt.message.contains("4 clips"))
        #expect(prompt.message.contains("including 2 you added from elsewhere"))
        #expect(prompt.message.contains("“Demo combined.mp4”"))
        #expect(prompt.message.contains("Nothing else is touched"))
    }

    @Test func promptWithoutACombinedVideoWarnsAndOffersNoEverything() {
        let model = session(3)
        model.sessionRecordings = Set(model.clips.map(\.url))
        let prompt = model.clearPrompt
        #expect(!prompt.offersEverything)
        #expect(prompt.title.contains("without combining its 3 clips"))
        #expect(!prompt.message.contains("elsewhere"))
        #expect(!prompt.message.contains("Move Everything"))
    }

    // A combined video that was added back to the list counts as a clip, not as the session's output.
    @Test func combinedVideoAddedAsAClipIsntCountedTwice() throws {
        let folder = try TemporaryFolder()
        let output = folder.file("combined.mp4")
        try Data().write(to: output)
        let model = StitchModel()
        model.items = [.clip(makeClip("Clip 1.mov")), .clip(Clip(url: output, date: Date(), duration: 1, width: 2, height: 2,
                                                                 videoStream: 0, audioStreams: 0, fileSize: 0))]
        model.sessionOutputs = [output]
        #expect(model.existingOutputs.isEmpty)
    }

    @Test func changingTheListDropsTheCombinedResult() {
        let model = session(2)
        model.state = .done(output: URL(fileURLWithPath: "/tmp/out.mp4"), outputBytes: 1, inputBytes: 2)
        model.outputThumbnail = NSImage(size: CGSize(width: 16, height: 9))
        model.move(from: [0], to: 2)
        #expect(model.state == .idle)
        #expect(model.outputThumbnail == nil)
    }

    @Test func beforeAndAfterGoAroundTheFirstClip() {
        let model = session(2)
        model.toggleBeforeAndAfter()
        let order = model.items.map { $0.card?.text ?? $0.clip!.name }
        #expect(order == ["Before…", "Clip 1.mov", "After…", "Clip 2.mov"])
    }

    @Test func titleCardGoesAfterTheSelectedRow() {
        let model = session(3)
        model.selection = [model.clips[0].id]
        model.addTitleCard()
        #expect(model.items[1].card != nil)
        model.selection = []
        model.addTitleCard()
        #expect(model.items.last?.card != nil)
    }

    // Sorting puts the clips in recording order and leaves the cards in their places.
    @Test func sortingKeepsCardsInPlace() {
        let model = StitchModel()
        let late = makeClip("late.mov", date: Date(timeIntervalSince1970: 200))
        let early = makeClip("early.mov", date: Date(timeIntervalSince1970: 100))
        model.items = [.card(TitleCard(text: "Before…")), .clip(late), .card(TitleCard(text: "After…")), .clip(early)]
        model.sortByDate()
        #expect(model.items.map { $0.card?.text ?? $0.clip!.name } == ["Before…", "early.mov", "After…", "late.mov"])
    }

    @Test func editingACardChangesOnlyThatCard() {
        let model = session(2)
        model.toggleBeforeAndAfter()
        let before = model.titleCards[0].id
        model.updateCard(before) {
            $0.text = "Old version"
            $0.duration = 4
            $0.isLight = true
        }
        #expect(model.titleCards[0].text == "Old version" && model.titleCards[0].duration == 4 && model.titleCards[0].isLight)
        #expect(model.titleCards[1].text == "After…")
    }

    @Test func cardsRuleOutJoiningAndCountInTheLength() {
        let model = StitchModel()
        var first = makeClip("1.mov", duration: 5)
        var second = makeClip("2.mov", duration: 5)
        first.copyFormat = "video:h264:x"
        second.copyFormat = "video:h264:x"
        model.items = [.clip(first), .clip(second)]
        #expect(model.canCombineWithoutCompressing)
        model.toggleBeforeAndAfter()
        #expect(!model.canCombineWithoutCompressing)
        #expect(model.totalDuration == 12.5)
        #expect(model.summary.hasPrefix("2 clips · 2 title cards · 0:13"))
    }

    @Test func beforeAndAfterTurnsOffWithoutTouchingOtherCards() {
        let model = session(2)
        model.addTitleCard()
        model.toggleBeforeAndAfter()
        #expect(model.titleCards.count == 3)
        model.toggleBeforeAndAfter()
        #expect(model.titleCards.map(\.text) == ["Title"])
        #expect(!model.hasBeforeAndAfter)
    }

    @Test func beforeAndAfterIsOnlyForTwoClips() {
        #expect(!session(1).canAddBeforeAndAfter)
        #expect(!session(3).canAddBeforeAndAfter)
        let two = session(2)
        #expect(two.canAddBeforeAndAfter)
        two.toggleBeforeAndAfter()
        #expect(!two.canAddBeforeAndAfter)
        let three = session(3)
        three.toggleBeforeAndAfter()
        #expect(three.titleCards.isEmpty)
    }

    // Space on a title card previews the card itself, not a clip.
    @Test func quickLookShowsATitleCardAsAPicture() throws {
        let model = session(2)
        model.toggleBeforeAndAfter()
        model.selection = [model.titleCards[0].id]
        let items = model.quickLookItems
        #expect(items.count == 1)
        let picture = try #require(items.first)
        #expect(picture.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: picture.path))
        try? FileManager.default.removeItem(at: picture)
    }

    @Test func arrowsStepThroughCardsToo() {
        let model = session(2)
        model.toggleBeforeAndAfter()
        model.selection = [model.items[0].id]
        model.moveSelection(by: 1)
        #expect(model.selection == [model.items[1].id])
        model.moveSelection(by: 1)
        #expect(model.items.first { model.selection.contains($0.id) }?.card?.text == "After…")
    }
}

