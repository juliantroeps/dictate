@preconcurrency import ApplicationServices
import AppKit

enum TextInjector {
    enum Result: Equatable {
        case injected
        case pasted
        case copiedToClipboard
    }

    /// True if there is a frontmost app with a focused, non-web text element
    /// that `inject` would write into directly (not via a clipboard fallback).
    @MainActor
    static func hasInjectableTarget() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        guard let focused = FocusedTextElementLocator.focusedElement(for: frontApp) else { return false }
        if focused.role == "AXWebArea" || FocusedTextElementLocator.isInsideWebArea(focused.element) {
            return false
        }
        return true
    }

    /// Insert text into the focused text field of the frontmost app.
    /// Falls back to clipboard paste, then clipboard-only.
    @MainActor
    static func inject(_ text: String) -> Result {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            copyToClipboard(text)
            return .copiedToClipboard
        }

        guard let focused = FocusedTextElementLocator.focusedElement(for: frontApp) else {
            AppLogger.input.debug("No focused text element, using \(TextInjectionStrategy.clipboardPaste.rawValue)")
            pasteViaClipboard(text)
            return .pasted
        }

        AppLogger.input.debug("Focused element role=\(focused.role)")

        if focused.role == "AXWebArea" || FocusedTextElementLocator.isInsideWebArea(focused.element) {
            AppLogger.input.debug("Web content detected, using \(TextInjectionStrategy.clipboardPaste.rawValue)")
            pasteViaClipboard(text)
            return .pasted
        }

        let beforeRange = FocusedTextElementLocator.selectedTextRange(of: focused.element)
        let axResult = AXUIElementSetAttributeValue(
            focused.element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if axResult == .success {
            if let before = beforeRange {
                let after = FocusedTextElementLocator.selectedTextRange(of: focused.element)
                if after?.location == before.location + text.utf16.count && after?.length == 0 {
                    AppLogger.input.info("Text injected using \(TextInjectionStrategy.accessibilityWrite.rawValue)")
                    return .injected
                }
                // AX write claimed success but cursor didn't advance - skip value-splice
                // to avoid double-injection in apps that accept AX writes but have
                // inconsistent cursor reporting (e.g. Ghostty, some Electron apps)
                AppLogger.input.debug("AX write succeeded but cursor unchanged, skipping value-splice")
                pasteViaClipboard(text)
                return .pasted
            } else {
                AppLogger.input.info("Text injected using \(TextInjectionStrategy.accessibilityWrite.rawValue)")
                return .injected
            }
        }

        if ValueSpliceInjector.inject(element: focused.element, text: text) {
            AppLogger.input.info("Text injected using \(TextInjectionStrategy.valueSplice.rawValue)")
            return .injected
        }

        AppLogger.input.debug("Falling back to \(TextInjectionStrategy.clipboardPaste.rawValue)")
        pasteViaClipboard(text)
        return .pasted
    }

    @MainActor
    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let restorer = ClipboardRestorer(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simulateCmdV()
        restorer.restore()
    }

    /// Last-resort `.copiedToClipboard` path: no frontmost app to paste into, so
    /// leave the dictation on the clipboard for the user to paste manually.
    /// Intentionally does NOT save/restore prior contents (unlike pasteViaClipboard) -
    /// the dictation must remain on the pasteboard after this returns.
    @MainActor
    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
