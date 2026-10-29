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
                EmptyStateView()
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
            if model.recordingState == .systemPicker || model.recordingState == .needsPermission {
                ZStack {
                    Color.black.opacity(0.15)
                    if model.recordingState == .systemPicker {
                        ChoosingCard()
                    } else {
                        PermissionNeeded()
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.recordingState == .picking },
            set: { presented in
                if !presented, model.recordingState == .picking {
                    model.cancelRecording()
                }
            }
        )) {
            TargetPicker()
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
            guard !model.isEncoding else { return false }
            model.add(urls)
            return true
        } isTargeted: { targeted in
            model.isDropTargeted = targeted && !model.isEncoding
        }
        // The start screen has its own buttons for all of this, so the toolbar waits until there's a clip.
        .toolbar {
            let locked = model.isEncoding || model.tools == nil
            if !model.clips.isEmpty {
                ToolbarItemGroup {
                    Toggle(isOn: Binding(get: { model.recordMicrophone }, set: { model.recordMicrophone = $0 })) {
                        Label("Record Microphone", systemImage: model.recordMicrophone ? "mic.fill" : "mic.slash")
                    }
                    .help(model.recordMicrophone ? "Turn off the microphone for new recordings" : "Turn on the microphone for new recordings")
                    .disabled(model.isRecording)
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

// Recording is the main use, so it gets the one big button. The alternatives are plain buttons whose details live in
// their tooltips, and where recordings go is a quiet footer.
struct EmptyStateView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        let watched = (model.watchFolder ?? StitchModel.screenshotFolder()).lastPathComponent
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

            Button { model.startRecording() } label: {
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
                Button { model.isWatching ? model.stopWatching() : model.startWatching() } label: {
                    Label(model.isWatching ? "Stop Watching" : "Watch for Recordings", systemImage: "eye")
                }
                .help(model.isWatching
                    ? "Stop adding new recordings from \(watched)"
                    : "Add recordings from the macOS Screenshot toolbar as soon as they're saved to \(watched)")
                Button { model.chooseFiles() } label: {
                    Label("Add Videos…", systemImage: "plus")
                }
                .help("Add existing video files")
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
                Button("Cancel") { model.cancelRecording() }
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
