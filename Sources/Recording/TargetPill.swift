import SwiftUI

// Start, or the time and Stop while recording, next to what's being recorded so it's close at hand. Like the other
// overlays it's left out of recordings. It goes below the target, or nowhere when there's no room there, unless it
// may sit just inside the target's bottom edge instead.
@MainActor
final class TargetPill {
    enum Mode: Equatable {
        case ready(size: CGSize?)
        case recording(since: Date)
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
    }

    private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private struct Content: View {
        let mode: Mode
        let now: Date
        let start: () -> Void
        let stop: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                switch mode {
                case let .ready(size):
                    if let size {
                        Text(verbatim: "\(Int(size.width))×\(Int(size.height))")
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    button("Start", systemImage: "record.circle", action: start)
                        .help("Start recording")
                case let .recording(since):
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Recording")
                    Text(verbatim: formatDuration(now.timeIntervalSince(since)))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    button("Stop", systemImage: "stop.fill", action: stop)
                        .help("Stop recording")
                }
            }
            .padding(.leading, mode == .ready(size: nil) ? 4 : 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.65), in: Capsule())
            .fixedSize()
        }

        private func button(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: systemImage)
                    Text(title)
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.red, in: Capsule())
        }
    }

    // Clears the frame drawn around the target.
    nonisolated static let gap: CGFloat = 16

    private let panel: Panel
    private let host: FirstClickHostingView<Content>
    private let start: () -> Void
    private let stop: () -> Void
    private var mode: Mode
    private var placement: (target: CGRect, gap: CGFloat, screen: CGRect, insideIfNeeded: Bool)?
    private var clock: Timer?

    init(start: @escaping () -> Void, stop: @escaping () -> Void) {
        self.start = start
        self.stop = stop
        mode = .ready(size: nil)
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.canHide = false
        panel.sharingType = .none
        host = FirstClickHostingView(rootView: Content(mode: mode, now: Date(), start: start, stop: stop))
        panel.contentView = host
    }

    // Centered `gap` below `target` and inside `screen`, or just inside the target's bottom edge when `insideIfNeeded`.
    // Nil when neither fits.
    nonisolated static func origin(for size: CGSize, below target: CGRect, gap: CGFloat, within screen: CGRect, insideIfNeeded: Bool) -> CGPoint? {
        var origin = CGPoint(x: target.midX - size.width / 2, y: target.minY - gap - size.height)
        if origin.y < screen.minY + 4 {
            guard insideIfNeeded else { return nil }
            origin.y = target.minY + gap
        }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        return origin
    }

    func show(_ mode: Mode, below target: CGRect, gap: CGFloat = gap, within screen: CGRect, insideIfNeeded: Bool) {
        placement = (target, gap, screen, insideIfNeeded)
        if mode != self.mode {
            self.mode = mode
            host.rootView = Content(mode: mode, now: Date(), start: start, stop: stop)
        }
        if case .recording = mode, clock == nil {
            let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(clock, forMode: .common)
            self.clock = clock
        }
        place()
    }

    // A wider time would otherwise grow the pill to the right.
    private func tick() {
        host.rootView = Content(mode: mode, now: Date(), start: start, stop: stop)
        place()
    }

    private func place() {
        guard let placement else { return }
        let size = host.fittingSize
        guard let origin = Self.origin(for: size, below: placement.target, gap: placement.gap, within: placement.screen,
                                       insideIfNeeded: placement.insideIfNeeded) else {
            panel.orderOut(nil)
            return
        }
        let frame = CGRect(origin: origin, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        clock?.invalidate()
        clock = nil
        placement = nil
        panel.orderOut(nil)
    }
}
