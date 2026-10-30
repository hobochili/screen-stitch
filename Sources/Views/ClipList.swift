import SwiftUI

struct ClipList: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ClipListHeader()
            Divider()
            let numbers = Dictionary(uniqueKeysWithValues: model.clips.enumerated().map { ($1.id, $0 + 1) })
            List(selection: $model.selection) {
                ForEach(model.items) { item in
                    switch item {
                    case let .clip(clip):
                        ClipRow(number: numbers[clip.id] ?? 0, clip: clip)
                    case let .card(card):
                        TitleCardRow(card: card)
                    }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .disabled(model.isEncoding)
            Divider()
            RecordAnotherBar()
        }
    }
}

struct ClipListHeader: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            Text(verbatim: model.clips.count == 1 ? "Session · 1 clip" : "Session · \(model.clips.count) clips")
                .font(.headline)
            Text(model.isDateOrdered ? "In recording order. Drag to reorder." : "Custom order. New clips go at the end.")
                .foregroundStyle(.secondary)
            Spacer()
            Menu("Title Cards") {
                if model.hasBeforeAndAfter || model.canAddBeforeAndAfter {
                    Toggle("Before & After", isOn: Binding(get: { model.hasBeforeAndAfter }, set: { _ in model.toggleBeforeAndAfter() }))
                }
                Button("Add Title Card") { model.addTitleCard() }
            }
            .fixedSize()
            .help("Add text shown between clips in the combined video")
            Button("Sort by Date") { model.sortByDate() }
                .disabled(model.isDateOrdered || model.clips.count < 2)
                .help("Put the clips back in the order they were recorded")
            Button("Clear Session") { model.clearSession() }
                .help("Start a new session. You can choose to move its files to the Trash.")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .disabled(model.isEncoding || model.recording.isRecording)
    }
}

struct RecordAnotherBar: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            if model.recording.lastTarget == nil {
                Button { model.recording.startRecording() } label: {
                    Label("Record Screen", systemImage: "record.circle")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .fixedSize()
            } else {
                RecordSplitButton()
            }
            LastTargetLine()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .disabled(model.isEncoding || model.recording.isRecording)
    }
}

// Record Another with an arrow for Record Something Else…. SwiftUI's own split button (a Menu with a primary action)
// stays grey whatever its tint, so this one is drawn to the same size in red.
struct RecordSplitButton: View {
    @Environment(StitchModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled

    // AppKit draws a menu's label in the text color, black in light mode, whatever color SwiftUI asks for. A symbol
    // with its own color keeps it.
    private static let arrow = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Record something else")!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))!

    var body: some View {
        HStack(spacing: 0) {
            Button { model.recording.startRecording() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle")
                    Text("Record Another")
                }
                .padding(.horizontal, 13)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Record the same thing again")
            Rectangle()
                .fill(.white.opacity(0.35))
                .frame(width: 1, height: 16)
            Menu {
                Button("Record Something Else…") { model.recording.pickTarget() }
            } label: {
                Image(nsImage: Self.arrow)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 28)
            .padding(.trailing, 3)
            .help("Record something else")
        }
        .foregroundStyle(.white)
        .background(Color.red, in: Capsule())
        .opacity(isEnabled ? 1 : 0.5)
        .fixedSize()
    }
}

// What Record Another will record. The label is secondary and the target primary, so the eye lands on the target.
struct LastTargetLine: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        if case let .window(_, pid, title)? = model.recording.lastTarget {
            let app = NSRunningApplication(processIdentifier: pid)
            HStack(spacing: 6) {
                Text("Same as last time:")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if let icon = app?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(app?.localizedName.map { $0 == title ? $0 : "\($0): \(title)" } ?? title)
        } else if let last = model.recording.lastTarget {
            HStack(spacing: 6) {
                Text("Same as last time:")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(verbatim: last.phrase)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text("Pick a window, display or area to record. The recording is added to this session when you stop.")
                .foregroundStyle(.secondary)
        }
    }
}

// A video's thumbnail with a play button, cropped to fill its box.
struct PreviewThumbnail: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 54)
            }
            Image(systemName: "play.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.black.opacity(0.5), in: Circle())
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// A title card in the list: its text, how long it shows, and white on black or black on white.
struct TitleCardRow: View {
    @Environment(StitchModel.self) private var model
    let card: TitleCard

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "textformat")
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            ZStack {
                card.isLight ? Color.white : Color.black
                Text(verbatim: card.text)
                    .font(.system(size: 10, weight: .medium, design: .serif))
                    .foregroundStyle(card.isLight ? Color.black : Color.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(6)
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: Binding(get: { card.text }, set: { text in model.updateCard(card.id) { $0.text = text } }))
                    .textFieldStyle(.roundedBorder)
                Text("Title card")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // Typed or stepped by a quarter second; kept to two decimals and within the allowed range.
            let seconds = Binding<Double>(get: { card.duration }, set: { value in
                let rounded = (value * 100).rounded() / 100
                model.updateCard(card.id) { $0.duration = min(max(rounded, TitleCard.durations.lowerBound), TitleCard.durations.upperBound) }
            })
            HStack(spacing: 4) {
                TextField("Seconds", value: seconds, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Text("sec")
                    .foregroundStyle(.secondary)
                Stepper("Seconds", value: seconds, in: TitleCard.durations, step: 0.25)
                    .labelsHidden()
            }
            .fixedSize()
            .help("How long the card shows, from 0.25 to 10 seconds")
            Picker("Style", selection: Binding(get: { card.isLight }, set: { light in model.updateCard(card.id) { $0.isLight = light } })) {
                Text("Dark").tag(false)
                Text("Light").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("White text on black, or black text on white")
            Button {
                model.remove(item: card.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Remove from List")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Remove from List") { model.remove(item: card.id) }
        }
    }
}

struct ClipRow: View {
    @Environment(StitchModel.self) private var model
    let number: Int
    let clip: Clip

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            Button {
                model.preview(clip)
            } label: {
                PreviewThumbnail(image: model.thumbnails[clip.id])
            }
            .buttonStyle(.plain)
            .help("Preview")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: clip.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(abbreviatedPath(clip.url))
                Text(clip.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if clip.audioStreams > 0 {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                    .help("Has audio")
            }
            Text(verbatim: "\(clip.width)×\(clip.height)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: formatDuration(clip.duration))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
            Text(verbatim: formatBytes(clip.fileSize))
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            Button {
                model.remove(clip)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Remove from List")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Preview") { model.preview(clip) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            Button("Remove from List") { model.remove(clip) }
        }
    }
}
