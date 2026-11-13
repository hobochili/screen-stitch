import Foundation
import Testing

@MainActor
@Suite(.enabled(if: tools != nil, "needs FFmpeg"), .serialized)
struct ExportQueueTests {
    private let folder: TemporaryFolder

    init() throws {
        folder = try TemporaryFolder()
    }

    private func clip(_ name: String, seconds: Double = 1) throws -> SessionItem {
        try makeVideo(folder.file(name), width: 320, height: 240, seconds: seconds)
        return .clip(try Prober.probe(folder.file(name), ffprobe: tools!.ffprobe))
    }

    private func model(_ names: [String]) throws -> StitchModel {
        let model = StitchModel()
        model.useGlobalShortcuts = false
        model.items = try names.map { try clip($0) }
        return model
    }

    private func waitForExports(_ model: StitchModel) async throws {
        for _ in 0..<400 where model.isExporting {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func theNextSessionCanBeCombinedWhileTheLastOneSaves() async throws {
        let model = try model(["1.mov", "2.mov"])
        model.encode(to: folder.file("first.mp4"))
        model.clearSession(.keepFiles)
        model.items = [try clip("3.mov")]
        model.encode(to: folder.file("second.mp4"))
        #expect(model.exports.map(\.status) == [.running, .waiting])
        try await waitForExports(model)
        #expect(model.exports.allSatisfy { if case .done = $0.status { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: folder.file("first.mp4").path))
        // Each video shows only in the session it came from.
        #expect(model.sessionOutputs.map(\.lastPathComponent) == ["second.mp4"])
        if case let .done(output, _, _) = model.state {
            #expect(output.lastPathComponent == "second.mp4")
        } else {
            Issue.record("the second session should show its saved video")
        }
    }

    @Test func clipsBeingExportedStayOutOfTheTrash() async throws {
        let model = try model(["1.mov", "2.mov"])
        var trashed: [URL] = []
        model.moveToTrash = { url in
            trashed.append(url)
            return nil
        }
        model.encode(to: folder.file("out.mp4"))
        model.trash([model.clips[0].id])
        #expect(trashed.isEmpty)
        #expect(model.warning == "“1.mov” is part of a video that's still being saved. Move it to the Trash once that's done.")
        #expect(model.clearPrompt.message.hasSuffix("Clips in videos that are still being saved stay where they are."))
        model.clearSession(.moveClips)
        #expect(trashed.isEmpty)
        #expect(model.notice == "Kept 2 clips that are still being saved.")
        try await waitForExports(model)
        #expect(FileManager.default.fileExists(atPath: folder.file("out.mp4").path))
    }

    @Test func aWaitingExportCanBeCancelledAndTheSameFileIsntSavedTwice() async throws {
        let model = try model(["1.mov"])
        model.encode(to: folder.file("a.mp4"))
        model.encode(to: folder.file("a.mp4"))
        #expect(model.exports.count == 1)
        #expect(model.state == .failed("“a.mp4” is already being saved. Choose a different name, or wait until it's done."))
        model.encode(to: folder.file("b.mp4"))
        let waiting = try #require(model.exports.last)
        #expect(waiting.status == .waiting)
        model.cancel(waiting)
        #expect(waiting.status == .cancelled)
        try await waitForExports(model)
        #expect(!FileManager.default.fileExists(atPath: folder.file("b.mp4").path))
        #expect(model.logLines.contains { $0.text.hasPrefix("Queued “a.mp4”") })
    }
}
