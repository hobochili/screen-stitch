import SwiftUI

@main
enum Launcher {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--cli" {
            CLI.run(Array(arguments.dropFirst()))
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
            CommandMenu("Record") {
                RecordCommands(model: appDelegate.model)
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

struct FileCommands: View {
    let model: StitchModel

    var body: some View {
        let busy = model.isEncoding || model.recording.isRecording || model.tools == nil
        Button("Add Videos…") { model.chooseFiles() }
            .keyboardShortcut("o")
            .disabled(busy)
        Divider()
        Button("Sort by Date") { model.sortByDate() }
            .disabled(busy || model.clips.count < 2)
        Button("Clear Session") { model.clearSession() }
            .keyboardShortcut("n")
            .disabled(busy || (model.clips.isEmpty && model.state == .idle))
    }
}

struct RecordCommands: View {
    let model: StitchModel

    var body: some View {
        let busy = model.isEncoding || model.tools == nil
        Button(model.recording.isCapturing ? "Stop Recording" : "Record Screen") { model.recording.toggleRecording() }
            .keyboardShortcut("r")
            .disabled(busy || (model.recording.isRecording && !model.recording.isCapturing))
        Button("Record Something Else…") { model.recording.pickTarget() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(busy || model.recording.isRecording)
    }
}
