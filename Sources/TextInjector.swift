@preconcurrency import ApplicationServices
import AppKit

enum TextInjector {

    enum Result {
        case injected          // AX selectedText or value write
        case pasted            // clipboard + Cmd+V fallback
        case copiedToClipboard // no focused field, text on clipboard
    }

    /// Insert text into the focused text field of the frontmost app.
    /// Falls back to clipboard paste, then clipboard-only.
    @MainActor
    static func inject(_ text: String) -> Result {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            copyToClipboard(text)
            return .copiedToClipboard
        }

        guard let (focused, role) = focusedElement(for: frontApp) else {
            print("[dikt] TextInjector: no focused text element, trying clipboard paste")
            pasteViaClipboard(text)
            return .pasted
        }

        print("[dikt] TextInjector: focused element role=\(role)")

        // Web areas (browsers): AX attribute writes are unreliable → clipboard paste
        if role == "AXWebArea" {
            print("[dikt] TextInjector: AXWebArea detected, using clipboard paste")
            pasteViaClipboard(text)
            return .pasted
        }

        // Strategy 1: Set AXSelectedText, then verify cursor actually advanced.
        // Some apps (terminal emulators) return success but silently discard the write.
        let beforeRange = selectedTextRange(of: focused)
        let axResult = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if axResult == .success {
            if let before = beforeRange {
                let after = selectedTextRange(of: focused)
                if after?.location == before.location + text.utf16.count && after?.length == 0 {
                    return .injected
                }
                print("[dikt] TextInjector: Strategy 1 silently failed (cursor didn't advance), falling through")
            } else {
                return .injected  // can't verify, trust the return value
            }
        }

        // Strategy 2: Read AXValue + AXSelectedTextRange, splice, write back
        if insertViaValueSplice(element: focused, text: text) {
            print("[dikt] TextInjector: Strategy 2 (value-splice) succeeded")
            return .injected
        }

        // Strategy 3: Clipboard + Cmd+V
        print("[dikt] TextInjector: falling back to clipboard paste")
        pasteViaClipboard(text)
        return .pasted
    }

    // MARK: - Helpers

    private static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Focused Element

    private static func focusedElement(for frontApp: NSRunningApplication) -> (AXUIElement, String)? {
        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appRef,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard result == .success, let element = focusedValue else {
            print("[dikt] TextInjector: no focused UI element (app=\(frontApp.localizedName ?? "?"))")
            return nil
        }

        let axElement = element as! AXUIElement

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        let role = (roleValue as? String) ?? "unknown"

        let textRoles: Set<String> = [
            kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
            "AXSearchField", "AXWebArea",
        ]
        if textRoles.contains(role) {
            return (axElement, role)
        }
        // Catch custom editable controls
        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &isSettable)
        if isSettable.boolValue {
            return (axElement, role)
        }

        print("[dikt] TextInjector: focused element not a text input (role=\(role))")
        return nil
    }

    // MARK: - Strategy 2: Value Splice

    private static func insertViaValueSplice(element: AXUIElement, text: String) -> Bool {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let currentValue = valueRef as? String else { return false }

        guard let range = selectedTextRange(of: element) else { return false }

        let newValue = (currentValue as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: text
        )

        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success else { return false }

        // Reposition cursor to end of inserted text
        let newCursorPos = range.location + text.utf16.count
        var newRange = CFRange(location: newCursorPos, length: 0)
        if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
        }

        // Verify the write took effect
        guard let afterRange = selectedTextRange(of: element),
              afterRange.location == newCursorPos, afterRange.length == 0 else {
            print("[dikt] TextInjector: Strategy 2 silently failed (cursor didn't advance), falling through")
            return false
        }

        return true
    }

    // MARK: - Strategy 3: Clipboard Paste

    private static func pasteViaClipboard(_ text: String) {
        copyToClipboard(text)
        simulateCmdV()
    }

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
