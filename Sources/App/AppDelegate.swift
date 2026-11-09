import AppKit
import Carbon.HIToolbox
import Quartz

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = StitchModel()
    private var terminationSignal: DispatchSourceSignal?
    private var keyMonitor: Any?

    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls)
    }

    // Quit when the main window closes. AppKit's "terminate after last window closed" (SwiftUI turns it on for
    // single-Window apps) also fires when the recording controls go away while the window is hidden, which quit
    // the app on Stop.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            guard (notification.object as? NSWindow)?.identifier?.rawValue == "main" else { return }
            RunLoop.main.perform { NSApp.terminate(nil) }
        }

        // Space opens Quick Look from anywhere in the main window, not only when the list has focus, unless text is
        // being typed. ⌘Delete in a title card's text deletes to the start of the line, as in any text field, instead
        // of moving the selected clips to the Trash.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [model] event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard let window = event.window, window.identifier?.rawValue == "main" else { return event }
            if Int(event.keyCode) == kVK_Delete, modifiers == .command, let text = window.firstResponder as? NSTextView {
                MainActor.assumeIsolated { text.deleteToBeginningOfLine(nil) }
                return nil
            }
            guard Int(event.keyCode) == kVK_Space, modifiers.isEmpty, !(window.firstResponder is NSText) else { return event }
            return MainActor.assumeIsolated { model.toggleQuickLook() } ? nil : event
        }

        // `build.sh --install` sends SIGTERM; quit the normal way so an export in progress is cleaned up.
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Quitting can wait for a recording to finish, which needs the main queue, so it can't run inside one of its blocks.
        terminationSignal?.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
        terminationSignal?.resume()

        model.updateGlobalShortcuts()
        model.restoreSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.updateGlobalShortcuts()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.recording.finishRecordingBeforeQuit { NSApp.reply(toApplicationShouldTerminate: true) } ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.abortForQuit()
        model.saveSession()
    }

    // Quick Look asks the responder chain for a controller, and the chain ends at the app delegate.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension AppDelegate: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        model.quickLookItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let items = model.quickLookItems
        return items.indices.contains(index) ? items[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch Int(event.keyCode) {
        case kVK_UpArrow: model.moveSelection(by: -1)
        case kVK_DownArrow: model.moveSelection(by: 1)
        default: return false
        }
        return true
    }
}
