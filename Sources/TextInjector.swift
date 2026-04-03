@preconcurrency import ApplicationServices
import AppKit

enum TextInjector {
    enum Result: Equatable {
        case injected
        case pasted
        case copiedToClipboard
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
                AppLogger.input.debug("Accessibility write did not advance the cursor, falling through")
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
