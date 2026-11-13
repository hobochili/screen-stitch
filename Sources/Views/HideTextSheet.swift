import AVKit
import SwiftUI

// The Redact Text list: text to cover in every clip, remembered between sessions.
struct HideTextListSheet: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let lines = model.hiddenTextDraft.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let canAdd = lines.contains { $0.count >= 2 }
        // Return adds what's typed, and closes the sheet once the field is empty.
        let addKey: KeyboardShortcut? = canAdd ? KeyboardShortcut.defaultAction : nil
        let doneKey: KeyboardShortcut? = canAdd ? nil : KeyboardShortcut.defaultAction
        let hint: String = !lines.isEmpty && !canAdd ? "Type at least 2 characters." : "Type it as it appears on screen. Capital letters don't matter."
        let add = {
            if model.addHiddenText(model.hiddenTextDraft) == nil {
                model.hiddenTextDraft = ""
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Redact Text in the Video")
                    .font(.headline)
                Spacer()
                Toggle("Redact Text", isOn: $model.redactsText)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(model.redactsText ? "Turn off to keep the list but stop redacting" : "Turn on to redact the checked text")
            }
            Text("Type text to redact from the video, such as the last four digits of a card. A black box covers it everywhere it appears, in every clip. You can't remove the boxes from the saved video.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    // Pasting several lines adds each as its own entry.
                    TextField("Text to redact", text: $model.hiddenTextDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button("Add", action: add)
                        .disabled(!canAdd)
                        .keyboardShortcut(addKey)
                }
                Text(verbatim: hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.hiddenText.isEmpty {
                List {
                    ForEach(model.hiddenText) { entry in
                        HiddenTextEntryRow(entry: entry)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(minHeight: 90, maxHeight: 220)
                .disabled(!model.redactsText)
                Text(model.redactsText
                    ? "Screen Stitch remembers this list. Uncheck text to stop redacting it for now."
                    : "Redact Text is off. Your list is kept for next time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if !model.hiddenText.isEmpty {
                    Button("Clear List…") { model.confirmsClearHiddenText = true }
                }
                Spacer()
                Button("Done") { model.showsHideTextList = false }
                    .keyboardShortcut(doneKey)
            }
        }
        .padding(20)
        .frame(width: 440)
        .confirmationDialog("Clear the Redact Text list?", isPresented: $model.confirmsClearHiddenText) {
            Button("Clear List", role: .destructive) { model.clearHiddenText() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.hiddenText.count == 1 ? "This removes the only entry." : "This removes all \(model.hiddenText.count) entries.")
        }
    }
}

// An entry in the Redact Text list: its checkbox, how often it was found, and a button to remove it.
struct HiddenTextEntryRow: View {
    @Environment(StitchModel.self) private var model
    let entry: HiddenTextEntry

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { entry.isOn }, set: { model.setHiddenText(entry.text, isOn: $0) })) {
                Text(verbatim: entry.text)
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            if let status = model.hiddenTextStatus(entry) {
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button {
                model.removeHiddenText(entry.text)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Stop Redacting")
        }
        .padding(.vertical, 2)
    }
}

// Check Redactions: the saved video, with every place text was covered, to play through before sharing.
struct HiddenTextReviewSheet: View {
    @Environment(StitchModel.self) private var model
    let review: HiddenTextReview

    var body: some View {
        @Bindable var review = review
        let places = review.places
        let missing = review.record.texts.filter { text in !places.contains { $0.text == text } }
        let count: String = places.count == 1 ? "Redacted in 1 place" : "Redacted in \(places.count) places"
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PlainPlayer(player: review.player, outline: review.outline)
                    .frame(minWidth: 560, minHeight: 380)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check Redactions")
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(verbatim: count)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if places.count > 1 {
                            Button { review.step(-1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless)
                                .disabled((review.current ?? 0) == 0)
                                .help("Previous Place")
                            Text(verbatim: "\((review.current ?? 0) + 1) of \(places.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button { review.step(1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless)
                                .disabled((review.current ?? 0) >= places.count - 1)
                                .help("Next Place")
                        }
                    }
                    List(selection: Binding(get: { review.current }, set: { index in
                        if let index, index != review.current { review.show(index) }
                    })) {
                        ForEach(places.indices, id: \.self) { index in
                            let place = places[index]
                            HStack(spacing: 10) {
                                if place.box != nil {
                                    Group {
                                        if let thumbnail = review.thumbnails[index] {
                                            Image(nsImage: thumbnail)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                        } else {
                                            Color.secondary.opacity(0.15)
                                        }
                                    }
                                    .frame(width: 96, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: place.text)
                                        .lineLimit(1)
                                    Text(verbatim: "Clip \(place.clip) · \(formatDuration(place.start))–\(formatDuration(place.end))")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .tag(index)
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: false))
                    ForEach(missing, id: \.self) { text in
                        Text(verbatim: "\(text) wasn't found in this video.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Still see something?") { review.showsHelp = true }
                        .linkButton()
                        .font(.callout)
                        .popover(isPresented: $review.showsHelp, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("If you can read text that should be redacted, add it to the list the way it appears on screen, then combine again. Very small text can't always be read. Leave that clip out or record it again.")
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Redact More Text…") {
                                    review.showsHelp = false
                                    model.opensHideTextListAfterReview = true
                                    model.closeHiddenTextReview()
                                }
                            }
                            .padding()
                            .frame(width: 300)
                        }
                }
                .padding()
                .frame(width: 320)
            }
            Divider()
            HStack {
                Text("Look at each place to check that its black box covers all of the text. Play it to watch it move.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.closeHiddenTextReview() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 920, height: 600)
    }
}

// The system player, with its usual controls, and an outline around one box while it's paused on it.
struct PlainPlayer: NSViewRepresentable {
    let player: AVPlayer
    var outline: CGRect?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        if let overlay = view.contentOverlayView {
            let outlineView = OutlineView(frame: overlay.bounds)
            outlineView.autoresizingMask = [.width, .height]
            outlineView.playerView = view
            overlay.addSubview(outlineView)
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard let outlineView = view.contentOverlayView?.subviews.first as? OutlineView, outlineView.box != outline else { return }
        outlineView.box = outline
        outlineView.needsDisplay = true
    }

    // Draws around a box given as a fraction of the video's frame, wherever the player has placed the video.
    final class OutlineView: NSView {
        weak var playerView: AVPlayerView?
        var box: CGRect?

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            layerContentsRedrawPolicy = .duringViewResize
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let box, let playerView else { return }
            let video = convert(playerView.videoBounds, from: playerView)
            guard video.width > 0, video.height > 0 else { return }
            let rect = CGRect(x: video.minX + box.minX * video.width, y: video.minY + box.minY * video.height,
                              width: box.width * video.width, height: box.height * video.height)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: -8, dy: -8), xRadius: 4, yRadius: 4)
            path.lineWidth = 3
            NSColor.systemYellow.setStroke()
            path.stroke()
        }
    }
}
