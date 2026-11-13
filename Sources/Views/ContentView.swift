import SwiftUI

// Command Line Tools lack the SwiftUIMacros plugin, so view state lives on the model instead of @State.
struct ContentView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.tools == nil {
                ContentUnavailableView {
                    Label("FFmpeg isn't installed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Screen Stitch uses FFmpeg to combine and compress clips. Install it with Homebrew (`brew install ffmpeg`), then click Quit & Reopen.")
                } actions: {
                    Button("Quit & Reopen") { model.relaunch() }
                }
            } else if model.clips.isEmpty {
                if model.isRestoringSlowly {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !model.isRestoring {
                    EmptyStateView()
                }
            } else {
                ClipList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.hasBottomBar {
                VStack(spacing: 0) {
                    Divider()
                    BottomBar()
                }
                .background(.background)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .overlay {
            if model.isProbing {
                ProgressView("Reading clips…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        // The permission card isn't a sheet: macOS won't quit an app with a sheet open, which breaks the
        // Quit & Reopen that granting Screen Recording asks for.
        .overlay {
            if model.recording.state == .systemPicker || model.recording.state == .needsPermission {
                ZStack {
                    Color.black.opacity(0.15)
                    if model.recording.state == .systemPicker {
                        ChoosingCard()
                    } else {
                        PermissionNeeded()
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.recording.state == .picking },
            set: { presented in
                if !presented, model.recording.state == .picking {
                    model.recording.cancelRecording()
                }
            }
        )) {
            TargetPicker()
                .environment(model)
        }
        .sheet(isPresented: Binding(get: { model.showsHideTextList }, set: { model.showsHideTextList = $0 })) {
            HideTextListSheet()
                .environment(model)
        }
        .sheet(item: Binding(get: { model.hiddenTextReview }, set: { if $0 == nil { model.closeHiddenTextReview() } }), onDismiss: {
            if model.opensHideTextListAfterReview {
                model.opensHideTextListAfterReview = false
                model.showsHideTextList = true
            }
        }) { review in
            HiddenTextReviewSheet(review: review)
                .environment(model)
        }
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { targeted in
            model.isDropTargeted = targeted
        }
        // Apart from Exports, the toolbar waits until there's a clip. Before then, the start screen and the File menu offer
        // the same things.
        .toolbar {
            let locked = model.tools == nil
            // Shown once anything has been exported, so finished exports and the log stay in reach.
            if !model.exports.isEmpty {
                ToolbarItem {
                    Button("Exports", systemImage: "arrow.down.circle") { model.showsExports.toggle() }
                        .help("Videos saved or being saved since Screen Stitch opened")
                        .popover(isPresented: Binding(get: { model.showsExports }, set: { model.showsExports = $0 }), arrowEdge: .bottom) {
                            ExportsList()
                                .environment(model)
                        }
                }
            }
            if !model.clips.isEmpty {
                ToolbarItemGroup {
                    Toggle(isOn: Binding(get: { model.recordMicrophone }, set: { model.recordMicrophone = $0 })) {
                        Label("Record Microphone", systemImage: model.recordMicrophone ? "mic.fill" : "mic.slash")
                    }
                    .help(model.recordMicrophone ? "Turn off the microphone for new recordings" : "Turn on the microphone for new recordings")
                    .disabled(model.recording.isRecording)
                    Toggle(isOn: Binding(get: { model.isWatching }, set: { $0 ? model.startWatching() : model.stopWatching() })) {
                        Label("Watch for Recordings", systemImage: "eye")
                    }
                    .help(model.isWatching
                        ? "Stop watching \(model.watchFolder?.lastPathComponent ?? "")"
                        : "Watch \(StitchModel.screenshotFolder().lastPathComponent) for new screen recordings")
                    Button("Add Videos…", systemImage: "plus") { model.chooseFiles() }
                        .help("Add video files to the list")
                        .disabled(locked)
                }
            }
        }
    }
}

// Recording is the main use, so it gets the one big button. Adding videos and Redact Text are plain buttons, and where
// recordings go is a quiet footer. Watch for Recordings is in the File menu.
struct EmptyStateView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                Text("Record clips, then stitch them into one video")
                    .font(.title2.weight(.semibold))
                Text("The finished video is a small MP4 that's easy to share.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.bottom, 32)

            Button { model.recording.startRecording() } label: {
                Label("Record Screen", systemImage: "record.circle")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 260)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.extraLarge)
            .padding(.bottom, 12)

            Text("Pick a window, display or area to record.")
                .foregroundStyle(.secondary)
            if model.useGlobalShortcuts {
                Text(verbatim: "Press \(model.recordCombo.label) in any app to choose what to record, then again to start and again to stop.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }

            HStack(spacing: 12) {
                VStack { Divider() }
                Text("or")
                    .foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .frame(width: 320)
            .padding(.top, 40)
            .padding(.bottom, 16)

            HStack(spacing: 12) {
                Button { model.chooseFiles() } label: {
                    Label("Add Videos…", systemImage: "plus")
                }
                .help("Add existing video files")
                // Set up before recording, so the first clips are searched as they come in.
                HideTextButton()
            }
            .controlSize(.large)
            Text("You can also drop video files anywhere in this window.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)

            Spacer()
            RecordingsFolderLine()
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingsFolderLine: View {
    @Environment(StitchModel.self) private var model

    // The path opens a menu, as a path in the Finder does. The menu brings its own padding, which stands in for a space.
    var body: some View {
        HStack(spacing: 0) {
            Text("Recordings save to")
                .foregroundStyle(.secondary)
            Menu {
                Button("Show in Finder") { model.showRecordingsFolder() }
                Button("Change Folder…") { model.chooseRecordingsFolder() }
            } label: {
                Text(verbatim: displayPath(model.recordingsFolder))
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .linkColor))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("Show the recordings folder in the Finder, or choose a different one")
        }
        .font(.caption)
    }
}

struct ChoosingCard: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Choose in the macOS picker", systemImage: "record.circle")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                step(1, "In the macOS picker, click the window, app or display you want to record.")
                step(2, "Recording starts right away, and this window hides.")
                step(3, "When you're done, click Stop in the floating bar at the top of the screen. Stop is also in the menu bar. The recording is added to this session.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Record Microphone", isOn: Binding(get: { model.recordMicrophone }, set: { model.recordMicrophone = $0 }))
                    .font(.caption)
                RecordingsFolderLine()
            }
            HStack {
                Spacer()
                Button("Cancel") { model.recording.cancelRecording() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 470)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.callout.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
