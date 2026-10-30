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
            StatusView()
            if let folder = model.watchFolder {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                    Text(verbatim: "Watching \(folder.lastPathComponent) for new screen recordings")
                    Button("Change…") { model.chooseWatchFolder() }
                        .buttonStyle(.link)
                    Button("Stop Watching") { model.stopWatching() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
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
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .disabled(model.isEncoding || model.recording.isRecording || model.tools == nil)
            }
        }
        .padding()
    }
}

struct StatusView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .encoding:
            HStack(spacing: 12) {
                ProgressView(value: model.progress)
                Text(verbatim: model.progressText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancel() }
            }
        case let .done(output, outputBytes, inputBytes):
            HStack(spacing: 14) {
                Button {
                    model.previewOutput()
                } label: {
                    PreviewThumbnail(image: model.outputThumbnail)
                }
                .buttonStyle(.plain)
                .help("Preview the saved video")
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(verbatim: "Saved \(output.lastPathComponent) · \(formatBytes(outputBytes))\(savings(outputBytes, inputBytes))")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    HStack(spacing: 8) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                        Button("Open") { NSWorkspace.shared.open(output) }
                        Spacer(minLength: 16)
                        Button("Clear Session") { model.clearSession() }
                            .buttonStyle(.borderedProminent)
                            .help("Start a new session. You can choose to move its files to the Trash.")
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
