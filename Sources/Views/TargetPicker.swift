import SwiftUI

struct TargetPicker: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose what to record")
                        .font(.title2.weight(.semibold))
                    Text("Pick a window, display or area. Recording starts when you click Start in the floating bar, which appears at the top of the screen.")
                        .foregroundStyle(.secondary)
                    if let warning = model.warning {
                        Label {
                            Text(verbatim: warning)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer()
                Toggle("Record Microphone", isOn: Binding(get: { model.recordMicrophone }, set: { model.recordMicrophone = $0 }))
                    .help("Adds your voice, not the sound your Mac plays. You can also change it in the floating bar before you click Start.")
            }
            .padding(20)
            Divider()
            Group {
                if model.targets.isEmpty {
                    ProgressView("Finding windows and displays…")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            section("Displays", model.targets.filter(\.isDisplay), includingArea: true)
                            section("Windows", model.targets.filter { !$0.isDisplay && $0.offScreenReason == nil }, includingArea: false)
                            section("Not on Screen", model.targets.filter { !$0.isDisplay && $0.offScreenReason != nil }, includingArea: false)
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                RecordingsFolderLine()
                Spacer()
                if model.recordingState == .picking {
                    Button("Use macOS Picker…") { model.useSystemPicker() }
                        .help("Use Apple's picker instead. It can't record an area.")
                }
                Button("Cancel") { model.cancelRecording() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 700, idealWidth: 880, minHeight: 480, idealHeight: 640)
    }

    @ViewBuilder
    private func section(_ title: String, _ targets: [CaptureTarget], includingArea: Bool) -> some View {
        if !targets.isEmpty || includingArea {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: title)
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], alignment: .leading, spacing: 18) {
                    if includingArea {
                        AreaTile()
                    }
                    ForEach(targets) { TargetTile(target: $0) }
                }
            }
        }
    }
}

struct TargetTile: View {
    @Environment(StitchModel.self) private var model
    let target: CaptureTarget

    var body: some View {
        let hovered = model.hoveredTarget == target.id
        Button {
            model.record(target)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                    if let thumbnail = target.thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else if let reason = target.offScreenReason {
                        VStack(spacing: 8) {
                            if let icon = target.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 48, height: 48)
                            }
                            Text(verbatim: reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovered ? Color.accentColor : .clear, lineWidth: 3))
                HStack(spacing: 6) {
                    if let icon = target.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: target.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: target.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                model.hoveredTarget = target.id
            } else if model.hoveredTarget == target.id {
                model.hoveredTarget = nil
            }
        }
        .help(target.offScreenReason == nil ? "Choose \(target.phrase)" : "Choose \(target.phrase). Screen Stitch will try to bring it back.")
    }
}

struct AreaTile: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        let hovered = model.hoveredTarget == "area"
        Button {
            model.selectArea()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .foregroundStyle(.secondary)
                        .padding(28)
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovered ? Color.accentColor : .clear, lineWidth: 3))
                HStack(spacing: 6) {
                    Image(systemName: "crop")
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Select Area")
                        Text("Drag to select part of the screen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                model.hoveredTarget = "area"
            } else if model.hoveredTarget == "area" {
                model.hoveredTarget = nil
            }
        }
        .help("Record just part of the screen")
    }
}

struct PermissionNeeded: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Screen Stitch needs Screen Recording access")
                .font(.title3.weight(.semibold))
            Text("Turn on Screen Stitch in System Settings › Privacy & Security › Screen & System Audio Recording, then click Quit & Reopen (here or in the macOS prompt). macOS only applies the change after a relaunch.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") { model.openScreenRecordingSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Quit & Reopen") { model.relaunch() }
            }
            HStack(spacing: 16) {
                Button("Use macOS Picker…") { model.useSystemPicker() }
                    .buttonStyle(.link)
                Button("Cancel") { model.cancelRecording() }
                    .buttonStyle(.link)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.callout)
        }
        .padding(28)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
    }
}
