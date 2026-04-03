@preconcurrency import ApplicationServices
import AppKit
import Foundation

enum TextInjectionStrategy: String {
    case accessibilityWrite
    case valueSplice
    case clipboardPaste
}

@MainActor
struct ClipboardRestorer {
    private let savedItems: [NSPasteboardItem]

    init(pasteboard: NSPasteboard = .general) {
        savedItems = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func restore(after delay: Duration = .milliseconds(350)) {
        let savedItems = savedItems
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            let pasteboard = NSPasteboard.general
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

enum FocusedTextElementLocator {
    static func focusedElement(for frontApp: NSRunningApplication) -> FocusedTextElement? {
        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appRef,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard result == .success, let element = focusedValue else {
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
            return FocusedTextElement(element: axElement, role: role)
        }

        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &isSettable)
        if isSettable.boolValue {
            return FocusedTextElement(element: axElement, role: role)
        }

        return nil
    }

    static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func isInsideWebArea(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<20 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { break }
            let axParent = parent as! AXUIElement
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axParent, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXWebArea" { return true }
            current = axParent
        }
        return false
    }
}

enum ValueSpliceInjector {
    static func inject(element: AXUIElement, text: String) -> Bool {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let currentValue = valueRef as? String else { return false }

        guard let range = FocusedTextElementLocator.selectedTextRange(of: element) else { return false }

        let newValue = (currentValue as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: text
        )

        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success else { return false }

        let newCursorPos = range.location + text.utf16.count
        var newRange = CFRange(location: newCursorPos, length: 0)
        if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
        }

        guard let afterRange = FocusedTextElementLocator.selectedTextRange(of: element),
              afterRange.location == newCursorPos, afterRange.length == 0 else {
            return false
        }

        return true
    }
}
