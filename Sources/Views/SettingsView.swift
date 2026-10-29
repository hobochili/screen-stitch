import SwiftUI

struct SettingsView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("Save recordings to") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: displayPath(model.recordingsFolder))
                    HStack {
                        Button("Change…") { model.chooseRecordingsFolder() }
                        Button("Show in Finder") { model.showRecordingsFolder() }
                        if model.recordingsFolder != StitchModel.defaultRecordingsFolder {
                            Button("Use Default") { model.recordingsFolder = StitchModel.defaultRecordingsFolder }
                        }
                    }
                }
            }
            captioned("Adds your voice to new recordings. Sound your Mac plays isn't recorded.") {
                Toggle("Record Microphone", isOn: Binding(get: { model.recordMicrophone }, set: { model.recordMicrophone = $0 }))
            }
            captioned("Appears for about a second and isn't recorded.") {
                Toggle("Briefly show “Recording” when recording starts", isOn: Binding(
                    get: { model.showsSlate },
                    set: { model.showsSlate = $0 }
                ))
            }
            captioned("Gives you a moment to get ready. The countdown isn't recorded.") {
                Toggle("Count down 3-2-1 before recording", isOn: Binding(
                    get: { model.countsDownBeforeRecording },
                    set: { model.countsDownBeforeRecording = $0 }
                ))
            }
            LabeledContent("Shortcuts") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Use from any app", isOn: Binding(get: { model.useGlobalShortcuts }, set: { model.useGlobalShortcuts = $0 }))
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            ShortcutField(action: .record)
                            Text("Press once to get ready, again to start, again to stop")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        GridRow {
                            ShortcutField(action: .show)
                            Text("Show Screen Stitch")
                        }
                    }
                    .disabled(!model.useGlobalShortcuts)
                    if let hint = model.shortcutHint {
                        Text(verbatim: hint)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem = model.shortcutProblem {
                        Text(verbatim: problem)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.shortcutClashesWithMacOS {
                            Button("Open Keyboard Settings…") { model.openKeyboardShortcutSettings() }
                        }
                    }
                    Text("Click a shortcut, then press the keys you want. The shortcuts work while Screen Stitch is open, even if another app is in front.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.recordCombo != .recordDefault || model.showCombo != .showDefault {
                        Button("Use Defaults") { model.useDefaultShortcuts() }
                            .disabled(!model.useGlobalShortcuts)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { model.updateGlobalShortcuts() }
        .onDisappear { model.endEditingShortcut() }
    }

    private func captioned(_ caption: LocalizedStringKey, @ViewBuilder toggle: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            toggle()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }
}

// Shows a global shortcut; click it, then press new keys.
struct ShortcutField: View {
    @Environment(StitchModel.self) private var model
    let action: StitchModel.ShortcutAction

    var body: some View {
        let editing = model.editingShortcut == action
        Button {
            model.editShortcut(action)
        } label: {
            Text(verbatim: editing ? "Press keys…" : model.combo(for: action).label)
                .foregroundStyle(editing ? Color.accentColor : .primary)
                .frame(minWidth: 64)
        }
        .help(editing ? "Press the keys you want, or Esc to cancel" : "Click, then press the keys you want")
    }
}
