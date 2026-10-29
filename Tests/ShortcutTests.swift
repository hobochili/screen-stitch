import AppKit
import Carbon.HIToolbox
import Testing

private func keyPress(_ keyCode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                     keyCode: UInt16(keyCode))!
}

private let control = UInt32(controlKey)
private let option = UInt32(optionKey)
private let shift = UInt32(shiftKey)
private let command = UInt32(cmdKey)

@Suite struct KeyComboTests {
    @Test func defaultsUseTwoModifiers() {
        #expect(KeyCombo.recordDefault.label == "⌃⌥R")
        #expect(KeyCombo.showDefault.label == "⌃⌥S")
    }

    @Test func modifiersShowInMenuOrder() {
        let combo = KeyCombo(keyCode: kVK_ANSI_5, modifiers: command | shift | option | control, key: "5")
        #expect(combo.label == "⌃⌥⇧⌘5")
    }

    @Test(arguments: [
        (control | option, kVK_ANSI_R, true),
        (shift | command, kVK_ANSI_5, true),
        (option | shift, kVK_ANSI_R, true),
        (command, kVK_ANSI_R, false),
        (control, kVK_ANSI_R, false),
        (shift, kVK_ANSI_R, false),
        (0, kVK_ANSI_R, false),
        (0, kVK_F5, true),
    ])
    func whichShortcutsAreAllowed(modifiers: UInt32, keyCode: Int, allowed: Bool) {
        #expect(KeyCombo(keyCode: keyCode, modifiers: modifiers, key: "").isAllowed == allowed)
    }

    @Test func keyPressShowsTheKeyNotWhatModifiersType() {
        // ⌥R types ® and ⇧5 types %, but the shortcut should read R and 5.
        #expect(KeyCombo(event: keyPress(kVK_ANSI_R, "®", [.control, .option])).label == "⌃⌥R")
        #expect(KeyCombo(event: keyPress(kVK_ANSI_5, "%", [.shift, .command])).label == "⇧⌘5")
        #expect(KeyCombo(event: keyPress(kVK_F5, "", [])).label == "F5")
    }

    @Test func survivesSaving() throws {
        let combo = KeyCombo(keyCode: kVK_ANSI_5, modifiers: shift | command, key: "5")
        #expect(try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(combo)) == combo)
    }

    @Test func matchingIgnoresTheShownKey() {
        let shown = KeyCombo(keyCode: kVK_ANSI_5, modifiers: shift | command, key: "5")
        #expect(shown.matches(KeyCombo(keyCode: kVK_ANSI_5, modifiers: shift | command, key: "")))
        #expect(!shown.matches(KeyCombo(keyCode: kVK_ANSI_5, modifiers: command, key: "5")))
    }
}

// The model's shortcuts are turned off first so the tests never take keys from the rest of the Mac.
@MainActor
@Suite(.serialized) struct ShortcutEditingTests {
    private func model() -> StitchModel {
        let model = StitchModel()
        model.useGlobalShortcuts = false
        model.recordCombo = .recordDefault
        model.showCombo = .showDefault
        return model
    }

    @Test func newKeysReplaceTheShortcut() {
        let model = model()
        model.editShortcut(.record)
        model.shortcutKeyPressed(keyPress(kVK_ANSI_T, "t", [.control, .option]))
        #expect(model.recordCombo.label == "⌃⌥T")
        #expect(model.editingShortcut == nil)
        model.useDefaultShortcuts()
    }

    @Test func oneModifierIsRefusedAndKeepsWaiting() {
        let model = model()
        model.editShortcut(.record)
        model.shortcutKeyPressed(keyPress(kVK_ANSI_R, "r", [.command]))
        #expect(model.recordCombo == .recordDefault)
        #expect(model.editingShortcut == .record)
        #expect(model.shortcutHint != nil)
        model.endEditingShortcut()
    }

    @Test func theOtherShortcutsKeysAreRefused() {
        let model = model()
        model.editShortcut(.record)
        model.shortcutKeyPressed(keyPress(kVK_ANSI_S, "s", [.control, .option]))
        #expect(model.recordCombo == .recordDefault)
        #expect(model.shortcutHint?.contains("⌃⌥S") == true)
        model.endEditingShortcut()
    }

    @Test func escCancels() {
        let model = model()
        model.editShortcut(.show)
        model.shortcutKeyPressed(keyPress(kVK_Escape, "\u{1b}", []))
        #expect(model.showCombo == .showDefault)
        #expect(model.editingShortcut == nil)
    }

    @Test func clickingTheFieldAgainCancels() {
        let model = model()
        model.editShortcut(.show)
        model.editShortcut(.show)
        #expect(model.editingShortcut == nil)
    }
}
