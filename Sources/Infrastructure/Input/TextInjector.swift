import AppKit
@preconcurrency import ApplicationServices
import Foundation

/// Opaque wrapper around an `AXUIElement` so the routing logic in `TextInjector.route`
/// doesn't need to touch ApplicationServices types directly - keeps `AXPort` fakeable.
struct AXElementHandle {
    let element: AXUIElement
}

struct AXFocusedTarget {
    let handle: AXElementHandle
    let role: String
    let isWebArea: Bool
}

enum AXLookup {
    case noFrontmostApp
    case noFocusedElement
    case element(AXFocusedTarget)
}

/// Seam between `TextInjector.route`'s decision logic and the real Accessibility APIs.
/// `SystemAXPort` is the production implementation; tests supply a fake to drive every
/// routing branch without touching real AX/clipboard state.
@MainActor
protocol AXPort {
    func lookup() -> AXLookup
    func readRange(_ handle: AXElementHandle) -> CFRange?
    func writeSelectedText(_ handle: AXElementHandle, _ text: String) -> Bool
    func writeValueSplice(_ handle: AXElementHandle, _ text: String) -> Bool
    /// Clipboard paste WITH restore of prior clipboard contents.
    func paste(_ text: String)
    /// Leaves `text` on the clipboard, no restore.
    func copyOnly(_ text: String)
}

enum TextInjector {
    enum Result: Equatable {
        case injected
        case pasted
        case copiedToClipboard
    }

    /// True if there is a frontmost app with a concrete focused text element that
    /// `inject` can place text into - a native field, or a real text input nested in
    /// web content (which `inject` pastes into via Cmd+V). A bare `AXWebArea`
    /// *container* means the page has keyboard focus but no specific input is
    /// selected (user clicked page chrome, not a field); that is NOT a real target,
    /// so it - like a wholly absent focus (Spotlight, the desktop) - returns false
    /// and is routed to the no-focus behavior (paste-and-keep with a notification).
    @MainActor
    static func hasInjectableTarget() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        guard let focused = FocusedTextElementLocator.focusedElement(for: frontApp) else { return false }
        return focused.role != "AXWebArea"
    }

    /// Insert text into the focused text field of the frontmost app.
    /// Falls back to clipboard paste, then clipboard-only.
    @MainActor
    static func inject(_ text: String) -> Result {
        route(text, port: SystemAXPort())
    }

    /// Routing decision, extracted from `inject` behind `AXPort` so it's testable
    /// without real Accessibility/clipboard state. Behavior must match `inject` exactly.
    @MainActor
    static func route(_ text: String, port: any AXPort) -> Result {
        switch port.lookup() {
        case .noFrontmostApp:
            port.copyOnly(text)
            return .copiedToClipboard

        case .noFocusedElement:
            AppLogger.input.debug("No focused text element, using \(TextInjectionStrategy.clipboardPaste.rawValue)")
            port.paste(text)
            return .pasted

        case .element(let target):
            AppLogger.input.debug("Focused element role=\(target.role)")

            if target.isWebArea {
                AppLogger.input.debug("Web content detected, using \(TextInjectionStrategy.clipboardPaste.rawValue)")
                port.paste(text)
                return .pasted
            }

            let beforeRange = port.readRange(target.handle)
            if port.writeSelectedText(target.handle, text) {
                if let before = beforeRange {
                    let after = port.readRange(target.handle)
                    if after?.location == before.location + text.utf16.count && after?.length == 0 {
                        AppLogger.input.info("Text injected using \(TextInjectionStrategy.accessibilityWrite.rawValue)")
                        return .injected
                    }
                    // AX write claimed success but cursor didn't advance - skip value-splice
                    // to avoid double-injection in apps that accept AX writes but have
                    // inconsistent cursor reporting (e.g. Ghostty, some Electron apps)
                    AppLogger.input.debug("AX write succeeded but cursor unchanged, skipping value-splice")
                    port.paste(text)
                    return .pasted
                } else {
                    AppLogger.input.info("Text injected using \(TextInjectionStrategy.accessibilityWrite.rawValue)")
                    return .injected
                }
            }

            if port.writeValueSplice(target.handle, text) {
                AppLogger.input.info("Text injected using \(TextInjectionStrategy.valueSplice.rawValue)")
                return .injected
            }

            AppLogger.input.debug("Falling back to \(TextInjectionStrategy.clipboardPaste.rawValue)")
            port.paste(text)
            return .pasted
        }
    }

    /// Marks the pasteboard entry as transient/concealed (`org.nspasteboard.*`) so
    /// clipboard managers (Raycast/Alfred/Maccy/Paste) skip recording it - dictations
    /// shouldn't linger in clipboard-manager history.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    @MainActor
    private static func declareTransient(on pasteboard: NSPasteboard) {
        pasteboard.setData(Data(), forType: transientType)
        pasteboard.setData(Data(), forType: concealedType)
    }

    @MainActor
    static func pasteViaClipboard(_ text: String, pasteboard: NSPasteboard = .general) {
        let restorer = ClipboardRestorer(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        declareTransient(on: pasteboard)
        simulateCmdV()
        restorer.restore()
    }

    /// No-detectable-field "paste anyway" path for the `.clipboard` no-focus mode:
    /// leave the dictation on the clipboard (persisting, unlike `pasteViaClipboard`
    /// which restores the prior contents) then fire Cmd+V. Lands in targets that
    /// have keyboard focus but expose no AX text element (Spotlight, some Electron);
    /// if the blind paste goes nowhere the text stays on the clipboard for a manual
    /// paste.
    @MainActor
    static func pasteKeepingClipboard(_ text: String, pasteboard: NSPasteboard = .general) {
        copyToClipboard(text, pasteboard: pasteboard)
        simulateCmdV()
    }

    /// Last-resort `.copiedToClipboard` path: no frontmost app to paste into, so
    /// leave the dictation on the clipboard for the user to paste manually.
    /// Intentionally does NOT save/restore prior contents (unlike pasteViaClipboard) -
    /// the dictation must remain on the pasteboard after this returns.
    @MainActor
    static func copyToClipboard(_ text: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        declareTransient(on: pasteboard)
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

/// Production `AXPort`: wraps `FocusedTextElementLocator` / `ValueSpliceInjector` /
/// `TextInjector`'s clipboard paths. No routing logic lives here - see `TextInjector.route`.
struct SystemAXPort: AXPort {
    func lookup() -> AXLookup {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return .noFrontmostApp
        }
        guard let focused = FocusedTextElementLocator.focusedElement(for: frontApp) else {
            return .noFocusedElement
        }
        let isWebArea = focused.role == "AXWebArea" || FocusedTextElementLocator.isInsideWebArea(focused.element)
        return .element(
            AXFocusedTarget(
                handle: AXElementHandle(element: focused.element),
                role: focused.role,
                isWebArea: isWebArea
            )
        )
    }

    func readRange(_ handle: AXElementHandle) -> CFRange? {
        FocusedTextElementLocator.selectedTextRange(of: handle.element)
    }

    func writeSelectedText(_ handle: AXElementHandle, _ text: String) -> Bool {
        let result = AXUIElementSetAttributeValue(
            handle.element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    func writeValueSplice(_ handle: AXElementHandle, _ text: String) -> Bool {
        ValueSpliceInjector.inject(element: handle.element, text: text)
    }

    func paste(_ text: String) {
        TextInjector.pasteViaClipboard(text)
    }

    func copyOnly(_ text: String) {
        TextInjector.copyToClipboard(text)
    }
}
