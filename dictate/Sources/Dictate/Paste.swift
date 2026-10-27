import AppKit
import ApplicationServices

enum PasteboardPutter {
    /// Put text on the clipboard and synthesize Command-V for the focused app.
    /// The previous clipboard text is restored shortly after. Returns false when
    /// Accessibility is missing; the text is still on the clipboard.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        let board = NSPasteboard.general
        let previous = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)
        let pastedChangeCount = board.changeCount
        guard AXIsProcessTrusted() else { return false }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            restore(previous, on: board, expectedChangeCount: pastedChangeCount)
        }
        return true
    }

    private static func restore(_ previous: String?, on board: NSPasteboard, expectedChangeCount: Int) {
        // A copy made during the paste delay belongs to the user.
        guard board.changeCount == expectedChangeCount else { return }
        board.clearContents()
        if let previous { board.setString(previous, forType: .string) }
    }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
