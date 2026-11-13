import SwiftUI

struct BottomBar: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        @Bindable var settings = model
        VStack(alignment: .leading, spacing: 12) {
            switch model.recording.state {
            case let .recording(since):
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(verbatim: "Recording \(formatDuration(context.date.timeIntervalSince(since)))")
                            .monospacedDigit()
                    }
                    Button("Stop") { model.recording.stopRecording() }
                }
            default:
                EmptyView()
            }
            ExportsLine()
            StatusView()
            if model.showsSavedLine {
                SavedVideosLine()
            }
            if let folder = model.watchFolder {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .foregroundStyle(.secondary)
                    Text(verbatim: "Watching \(folder.lastPathComponent) for new screen recordings")
                        .foregroundStyle(.secondary)
                    Button("Change…") { model.chooseWatchFolder() }
                        .linkButton()
                    Button("Stop Watching") { model.stopWatching() }
                        .linkButton()
                }
                .font(.caption)
            }
            HidingTextLine()
            if let warning = model.warning {
                Label {
                    Text(verbatim: warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
            }
            if let notice = model.notice {
                HStack(spacing: 8) {
                    Text(verbatim: notice)
                        .foregroundStyle(.secondary)
                    if let removal = model.removal {
                        if !removal.trashed.isEmpty {
                            Button("Put Back") { model.putBack() }
                                .linkButton()
                        } else {
                            if model.canTrashRemoved {
                                Button("Move to Trash") { model.trashRemoved() }
                                    .linkButton()
                            }
                            Button("Undo") { model.undoRemoval() }
                                .linkButton()
                        }
                    }
                }
                .font(.caption)
            }
            let summary = Text(verbatim: model.summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            let controls = HStack(spacing: 16) {
                Picker("Resolution", selection: $settings.outputSize) {
                    ForEach(OutputSize.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                .help("The video's maximum size; 1080p suits most uses. Clips smaller than the video aren't enlarged. They're centered with black bars around them.")
                Picker("Quality", selection: $settings.quality) {
                    ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .help("Higher quality makes a larger file")
                if model.canCombineWithoutCompressing {
                    Menu {
                        Button("Combine Without Compressing…") { model.chooseOutputAndEncode(compressing: false) }
                    } label: {
                        Text("Combine & Compress…")
                    } primaryAction: {
                        model.chooseOutputAndEncode()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(model.isProbing)
                } else {
                    Button(model.clips.count == 1 ? "Compress…" : "Combine & Compress…") { model.chooseOutputAndEncode() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.clips.isEmpty || model.isProbing)
                }
            }
            .fixedSize()
            if !model.clips.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        summary.fixedSize()
                        Spacer()
                        controls
                    }
                    VStack(alignment: .trailing, spacing: 10) {
                        summary.frame(maxWidth: .infinity, alignment: .leading)
                        controls
                    }
                }
                .disabled(model.recording.isRecording || model.tools == nil)
            }
        }
        .padding()
    }
}

// What the Redact Text list is redacting, and how the search is going. The icon is in the accent color, so a list
// remembered from an earlier session is hard to miss.
struct HidingTextLine: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        if let line = model.hidingLine {
            HStack(spacing: 6) {
                Image(systemName: "text.redaction")
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: line)
                    .foregroundStyle(.secondary)
                Button("Change…") { model.showsHideTextList = true }
                    .linkButton()
            }
            .font(.caption)
        }
    }
}

// Every video saved this session, once the full card has gone: the newest, or the one picked from the menu when there
// are several. The name can be dragged out, like the card's thumbnail.
struct SavedVideosLine: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        if let video = model.shownSavedVideo {
            let videos = model.savedVideos
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if videos.count > 1 {
                    Menu {
                        ForEach(videos, id: \.self) { url in
                            Toggle(Self.describe(url), isOn: Binding(get: { url == video }, set: { _ in model.shownVideo = url }))
                        }
                    } label: {
                        Text(verbatim: "\(videos.count) videos saved")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .linkColor))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Choose which saved video to show")
                } else {
                    Text("Saved")
                }
                Text(verbatim: Self.describe(video))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onDrag { NSItemProvider(contentsOf: video) ?? NSItemProvider() }
                    .help(abbreviatedPath(video))
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([video]) }
                    .linkButton()
                Button("Open") { NSWorkspace.shared.open(video) }
                    .linkButton()
                ShareLink(item: video) { Text("Share…") }
                    .linkButton()
                if model.hiddenRecord(for: video)?.places.isEmpty == false {
                    Button("Check Redactions…") { model.checkHiddenText(in: video) }
                        .linkButton()
                }
            }
            .font(.caption)
            if let note = model.staleNote(for: video) {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // "Demo combined.mp4 · 4.2 MB · 2:14 PM", with the date too if it wasn't saved today.
    static func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var parts = [url.lastPathComponent]
        if let size = values?.fileSize {
            parts.append(formatBytes(Int64(size)))
        }
        if let date = values?.contentModificationDate {
            parts.append(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}

struct StatusView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case let .done(output, outputBytes, inputBytes):
            HStack(spacing: 14) {
                Button {
                    model.previewOutput()
                } label: {
                    PreviewThumbnail(image: model.outputThumbnail)
                }
                .buttonStyle(.plain)
                .help("Preview the saved video")
                .onDrag { NSItemProvider(contentsOf: output) ?? NSItemProvider() }
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(verbatim: "Saved \(output.lastPathComponent) · \(formatBytes(outputBytes))\(savings(outputBytes, inputBytes))")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if let summary = model.hiddenSummary(for: output) {
                        Text(verbatim: summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    // Checking hidden text is the next step until it's been done. Sharing isn't held back.
                    let needsCheck = model.hiddenRecord(for: output)?.places.isEmpty == false
                        && !model.checkedVideos.contains(output.standardizedFileURL)
                    HStack(spacing: 8) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                        Button("Open") { NSWorkspace.shared.open(output) }
                        ShareLink(item: output) { Text("Share…") }
                        Spacer(minLength: 16)
                        if model.hiddenRecord(for: output)?.places.isEmpty == false {
                            if needsCheck {
                                Button("Check Redactions…") { model.checkHiddenText(in: output) }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button("Check Redactions…") { model.checkHiddenText(in: output) }
                            }
                        }
                        if needsCheck {
                            Button("Clear Session") { model.clearSession() }
                                .help("Start a new session. You can choose to move its files to the Trash.")
                        } else {
                            Button("Clear Session") { model.clearSession() }
                                .buttonStyle(.borderedProminent)
                                .help("Start a new session. You can choose to move its files to the Trash.")
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        case let .failed(message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(verbatim: message)
                    .font(.callout)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
        }
    }

    private func savings(_ outputBytes: Int64, _ inputBytes: Int64) -> String {
        guard inputBytes > 0 else { return "" }
        let ratio = Double(outputBytes) / Double(inputBytes)
        let percent = Int((abs(1 - ratio) * 100).rounded())
        return ratio <= 1 ? " (\(percent)% smaller)" : " (\(percent)% larger)"
    }
}

extension View {
    // A link-style button in the link color. SwiftUI's link style alone comes out grey.
    func linkButton() -> some View {
        buttonStyle(.link).foregroundStyle(Color(nsColor: .linkColor))
    }
}
