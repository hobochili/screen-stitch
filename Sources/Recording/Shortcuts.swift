import AppKit
import Carbon.HIToolbox

// A shortcut's key and modifiers, in the form Carbon's hot key API takes them. `key` is what the key types, for showing.
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt32
    var key: String

    static let recordDefault = KeyCombo(keyCode: kVK_ANSI_R, modifiers: UInt32(controlKey | optionKey), key: "R")
    static let showDefault = KeyCombo(keyCode: kVK_ANSI_S, modifiers: UInt32(controlKey | optionKey), key: "S")

    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
    private static let namedKeys: [Int: String] = {
        var names = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        for (index, keyCode) in functionKeys.enumerated() {
            names[keyCode] = "F\(index + 1)"
        }
        return names
    }()

    init(keyCode: Int, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let keyCode = Int(event.keyCode)
        let typed = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        self.init(keyCode: keyCode, modifiers: modifiers, key: Self.namedKeys[keyCode] ?? (typed.isEmpty ? "?" : typed))
    }

    // In the order macOS menus use.
    var label: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }
            .map(\.1)
            .joined() + key
    }

    // A global shortcut takes its keys away from every app, so it needs two modifiers; with one it would take a common
    // command, or a character people type. Function keys can go without.
    var isAllowed: Bool {
        let count = [controlKey, optionKey, shiftKey, cmdKey].filter { modifiers & UInt32($0) != 0 }.count
        return Self.functionKeys.contains(keyCode) || count >= 2
    }

    func matches(_ other: KeyCombo) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    // macOS's own shortcuts that are turned on, like ⇧⌘5 for the screenshot toolbar. They beat any app's, and macOS
    // still lets an app register the same keys, which then never arrive.
    static func systemShortcuts() -> [KeyCombo] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let hotKeys = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let mask = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return hotKeys.compactMap { hotKey in
            guard hotKey[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let keyCode = hotKey[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = hotKey[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }
            return KeyCombo(keyCode: keyCode, modifiers: UInt32(modifiers) & mask, key: "")
        }
    }
}

// System-wide shortcuts through Carbon's hot keys, which need no permission. They work while the app runs, even
// hidden, which is the point: the window is hidden while recording.
@MainActor
final class GlobalHotKeys {
    struct Shortcut {
        let keyCode: Int
        let modifiers: UInt32
        let label: String
        let action: () -> Void
    }

    private let signature: OSType
    private var registered: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    init(signature: OSType) {
        self.signature = signature
    }

    // The handler holds an unretained pointer to this object.
    deinit {
        registered.forEach { UnregisterEventHotKey($0) }
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    // Returns the labels of shortcuts that couldn't be registered, usually because another app holds them.
    func register(_ shortcuts: [Shortcut]) -> [String] {
        unregister()
        if handler == nil {
            installHandler()
        }
        var failed: [String] = []
        for (index, shortcut) in shortcuts.enumerated() {
            let id = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                registered.append(reference)
                actions[id.id] = shortcut.action
            } else {
                failed.append(shortcut.label)
            }
        }
        return failed
    }

    func unregister() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered = []
        actions = [:]
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            let hotKeys = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            let handled = MainActor.assumeIsolated { hotKeys.handle(id) }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    // Each instance installs its own handler, so one passes on the other's keys.
    private func handle(_ id: EventHotKeyID) -> Bool {
        guard id.signature == signature, let action = actions[id.id] else { return false }
        action()
        return true
    }
}
