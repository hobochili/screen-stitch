import SwiftUI

@main
enum Launcher {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--cli" {
            CLI.run(Array(arguments.dropFirst()))
        } else if arguments.first == "--find-text" {
            TextFinder.runAsWorker(Array(arguments.dropFirst()))
        } else {
            ScreenStitchApp.main()
        }
    }
}

struct ScreenStitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Screen Stitch", id: "main") {
            ContentView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                FileCommands(model: appDelegate.model)
            }
            CommandGroup(after: .pasteboard) {
                EditCommands(model: appDelegate.model)
            }
            CommandMenu("Record") {
                RecordCommands(model: appDelegate.model)
            }
        }

        Window("Export Log", id: "export-log") {
            ExportLogView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 640, height: 420)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

struct FileCommands: View {
    let model: StitchModel

    var body: some View {
        let busy = model.recording.isRecording || model.tools == nil
        Button("Add Videos…") { model.chooseFiles() }
            .keyboardShortcut("o")
            .disabled(busy)
        Toggle("Watch for Recordings", isOn: Binding(get: { model.isWatching }, set: { $0 ? model.startWatching() : model.stopWatching() }))
            .disabled(model.tools == nil)
        Divider()
        Button("Sort by Date") { model.sortByDate() }
            .disabled(busy || model.clips.count < 2)
        Button("Clear Session") { model.clearSession() }
            .keyboardShortcut("n")
            .disabled(busy || (model.clips.isEmpty && model.state == .idle && model.savedVideos.isEmpty))
    }
}

struct EditCommands: View {
    let model: StitchModel

    var body: some View {
        Divider()
        Button("Move to Trash") { model.trashItems(model.selection) }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.recording.isRecording || !model.selectionHasClips)
        Button("Redact Text…") { model.showsHideTextList = true }
    }
}

struct RecordCommands: View {
    let model: StitchModel

    var body: some View {
        let busy = model.tools == nil
        Button(model.recording.isCapturing ? "Stop Recording" : "Record Screen") { model.recording.toggleRecording() }
            .keyboardShortcut("r")
            .disabled(busy || (model.recording.isRecording && !model.recording.isCapturing))
        Button("Record Something Else…") { model.recording.pickTarget() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(busy || model.recording.isRecording)
    }
}
