import SwiftUI

// A floating bar that stays above every window and Space: Start/Cancel once something is picked, then the timer
// and Stop. The menu bar item mirrors its main action.
@MainActor
final class RecordingControls: NSObject {
    private final class HostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let panel: NSPanel
    private let content: NSView
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var model: StitchModel?
    private var ticker: Timer?

    // `screen` is where what's being recorded is, so Start is nearby.
    init(model: StitchModel, on screen: NSScreen? = nil) {
        self.model = model
        let content = HostingView(rootView: RecordingBar().environment(model))
        let size = content.fittingSize
        content.frame.size = size
        content.autoresizingMask = [.width, .height]
        self.content = content
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        // As the window's content view, a hosting view resizes the window from its left edge whenever the bar
        // changes; inside a plain container, refresh() sizes it around the center instead.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(content)
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.sharingType = .none
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()

        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(menuBarClicked)
        refresh()
    }

    // Resizes around the bar's current top center after the state changes what it shows. A detached hosting
    // view measures it, since the mounted one reports its current frame.
    func refresh() {
        guard let model else { return }
        let size = NSHostingView(rootView: RecordingBar().environment(model)).fittingSize
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        let capturing = model.recording.isCapturing
        item.button?.image = NSImage(systemSymbolName: capturing ? "stop.circle.fill" : "record.circle", accessibilityDescription: nil)
        item.button?.contentTintColor = capturing ? .systemRed : nil
        if capturing, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMenuBarTitle() }
            }
        } else if !capturing {
            ticker?.invalidate()
            ticker = nil
        }
        updateMenuBarTitle()
    }

    private func updateMenuBarTitle() {
        guard let model else { return }
        item.button?.title = switch model.recording.state {
        case let .recording(since): "Stop · \(formatDuration(Date().timeIntervalSince(since)))"
        case .starting: "Starting…"
        default: "Start Recording"
        }
    }

    @objc private func menuBarClicked() {
        model?.recording.primaryRecordingAction()
    }

    func remove() {
        ticker?.invalidate()
        ticker = nil
        panel.orderOut(nil)
        NSStatusBar.system.removeStatusItem(item)
    }
}

struct RecordingBar: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            switch model.recording.state {
            case let .ready(title):
                HStack(spacing: 8) {
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 2)
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "Ready to record \(title)")
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let note = model.recording.readyNote {
                            Text(verbatim: note)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Not recording yet. Click Start to begin.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                }
                .padding(.leading, 6)
                .windowDragHandle()
                Button {
                    model.recordMicrophone.toggle()
                } label: {
                    Image(systemName: model.recordMicrophone ? "mic.fill" : "mic.slash")
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.recordMicrophone ? .primary : .secondary)
                .help(model.recordMicrophone ? "Microphone on. Click to turn it off." : "Microphone off. Click to turn it on.")
                if model.recording.isWindowCovered {
                    Button("Bring to Front") { model.recording.bringWindowToFront() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Put the window you picked in front of the others. If System Settings opens, turn on Screen Stitch there, then click again.")
                }
                Button("Change…") { model.recording.changeTarget() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Pick a different window, display or area")
                Button("Cancel") { model.recording.cancelReady() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                pill("Start", systemImage: "record.circle") { model.recording.beginRecording() }
                    .help(model.useGlobalShortcuts ? "Start recording (\(model.recordCombo.label) from any app)" : "Start recording")
            case .starting:
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 6)
                Text("Starting…")
                    .font(.body.weight(.medium))
                    .padding(.trailing, 6)
            case let .recording(since):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(since)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.white)
                            .frame(width: 10, height: 10)
                            .opacity(Int(elapsed) % 2 == 0 ? 1 : 0.35)
                        Text(verbatim: "REC \(formatDuration(elapsed))")
                            .font(.body.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.leading, 6)
                .windowDragHandle()
                pill("Stop", systemImage: "stop.fill", inverted: true) { model.recording.stopRecording() }
                    .help(model.useGlobalShortcuts ? "Stop recording (\(model.recordCombo.label) from any app)" : "Stop recording")
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(model.recording.isCapturing ? AnyShapeStyle(Color.red) : AnyShapeStyle(.regularMaterial), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
    }

    // A custom style because prominent buttons turn gray in a panel that never becomes key.
    private func pill(_ title: String, systemImage: String, inverted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(inverted ? Color.red : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(inverted ? Color.white : .red, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func windowDragHandle() -> some View {
        contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .help("Drag to move")
    }
}
