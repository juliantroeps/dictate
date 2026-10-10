import AppKit
@preconcurrency import ApplicationServices
import Foundation

enum TextInjectionStrategy: String {
    case accessibilityWrite
    case valueSplice
    case clipboardPaste
}

@MainActor
struct ClipboardRestorer {
    private let pasteboard: NSPasteboard
    private let savedItems: [NSPasteboardItem]
    /// The dictation we placed on the pasteboard, so `restore` can tell "our write is
    /// still on top" (safe to restore) from "a genuine new copy replaced it" (skip),
    /// independently of `changeCount`.
    private let writtenText: String?

    init(pasteboard: NSPasteboard = .general, writtenText: String? = nil) {
        self.pasteboard = pasteboard
        self.writtenText = writtenText
        savedItems = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                // Skip promise-backed types (e.g. file-promise providers) - materializing
                // their data via `data(forType:)` resolves the promise on the main thread,
                // which we don't want just to snapshot the pasteboard for restore.
                if type.rawValue.lowercased().contains("promise") { continue }
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Callers construct the restorer BEFORE overwriting the pasteboard with the
    /// dictation (to snapshot the prior contents), then call `restore()` AFTER the
    /// write - so `pasteboard.changeCount` here is the post-write count. If the
    /// count differs when the delay elapses, restoring COULD clobber a concurrent
    /// copy - but browsers and clipboard managers bump `changeCount` while handling
    /// the paste even though our dictation is still on top, so a bare count check
    /// falsely strands the dictation on the clipboard. When we know the text we
    /// wrote, we treat "our write is still the top string" as safe to restore
    /// regardless of the count; only a genuinely different top item (a real new
    /// copy) is left untouched.
    func restore(after delay: Duration = .milliseconds(350)) {
        let savedItems = savedItems
        let pasteboard = pasteboard
        let writtenText = writtenText
        let savedChangeCount = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            let stillOurs = writtenText != nil && pasteboard.string(forType: .string) == writtenText
            guard pasteboard.changeCount == savedChangeCount || stillOurs else { return }
            pasteboard.clearContents()
            if !savedItems.isEmpty {
                pasteboard.writeObjects(savedItems)
            }
        }
    }
}

struct FocusedTextElement {
    let element: AXUIElement
    let role: String
}

/// Raw facts from one focus query on an app element. Kept separate from the verdict
/// (`TextInjector.classify`) so a "no target" decision can be explained in the log.
struct FocusProbe {
    /// Result of the `kAXFocusedUIElementAttribute` query itself.
    let error: AXError
    /// nil when the query failed or returned nothing.
    let element: AXUIElement?
    /// nil when there is no element; "unknown" when the element's role can't be read.
    let role: String?
    let valueSettable: Bool
}

enum FocusedTextElementLocator {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
        "AXSearchField", "AXWebArea",
    ]

    /// Single source of truth for "this focused element can take text".
    static func acceptsText(role: String, valueSettable: Bool) -> Bool {
        textRoles.contains(role) || valueSettable
    }

    static func probe(for frontApp: NSRunningApplication) -> FocusProbe {
        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appRef,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard result == .success, let element = focusedValue else {
            return FocusProbe(error: result, element: nil, role: nil, valueSettable: false)
        }

        let axElement = element as! AXUIElement

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)

        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &isSettable)

        return FocusProbe(
            error: result,
            element: axElement,
            role: (roleValue as? String) ?? "unknown",
            valueSettable: isSettable.boolValue
        )
    }

    static func focusedElement(for frontApp: NSRunningApplication) -> FocusedTextElement? {
        let probe = probe(for: frontApp)
        guard let element = probe.element, let role = probe.role,
            acceptsText(role: role, valueSettable: probe.valueSettable)
        else { return nil }
        return FocusedTextElement(element: element, role: role)
    }

    /// Diagnostic only (never changes a decision): extra focus-path facts logged next to
    /// a no-target verdict. Both are focus queries, not role reads on the app element,
    /// so they don't wake a cold web tree. `win` is the app's focused-window query
    /// (Chromium/Electron name the window even while the focused element is missing);
    /// `sys` is the system-wide focused element with its owning pid (frontmost-app
    /// attribution, e.g. Spotlight).
    static func diagnosticContext(for frontApp: NSRunningApplication) -> String {
        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)
        var windowValue: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedWindowAttribute as CFString, &windowValue)

        let systemWide = AXUIElementCreateSystemWide()
        var sysValue: CFTypeRef?
        let sysError = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &sysValue)
        var sysRole = "-"
        var sysPid = "-"
        if sysError == .success, let sysValue {
            let sysElement = sysValue as! AXUIElement
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(sysElement, kAXRoleAttribute as CFString, &roleValue)
            sysRole = (roleValue as? String) ?? "unknown"
            var pid: pid_t = 0
            if AXUIElementGetPid(sysElement, &pid) == .success { sysPid = String(pid) }
        }
        return "win=\(windowError.rawValue) sys=\(sysError.rawValue)/\(sysRole)/pid=\(sysPid)"
    }

    static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
        else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func isInsideWebArea(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<20 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                let parent = parentRef
            else { break }
            let axParent = parent as! AXUIElement
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axParent, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXWebArea" { return true }
            current = axParent
        }
        return false
    }
}

enum TextSplice {
    /// Returns the spliced string, or nil if the range is out of bounds for `value`.
    static func splice(value: String, range: CFRange, with text: String) -> String? {
        let nsValue = value as NSString
        let length = nsValue.length
        guard range.location >= 0,
            range.length >= 0,
            range.location <= length,
            length - range.location >= range.length
        else { return nil }
        return nsValue.replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: text
        )
    }
}

enum ValueSpliceInjector {
    static func inject(element: AXUIElement, text: String) -> Bool {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
            let currentValue = valueRef as? String
        else { return false }

        guard let range = FocusedTextElementLocator.selectedTextRange(of: element) else { return false }

        guard let newValue = TextSplice.splice(value: currentValue, range: range, with: text) else { return false }

        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success
        else { return false }

        let newCursorPos = range.location + text.utf16.count
        var newRange = CFRange(location: newCursorPos, length: 0)
        if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
        }

        guard let afterRange = FocusedTextElementLocator.selectedTextRange(of: element),
            afterRange.location == newCursorPos, afterRange.length == 0
        else {
            return false
        }

        return true
    }
}
