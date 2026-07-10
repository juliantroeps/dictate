import AppKit
@preconcurrency import ApplicationServices
import Testing

@testable import dictate

/// Records paste/copyOnly calls and returns scripted lookup/range/write results so
/// `TextInjector.route`'s branches can be exercised without real AX or clipboard state.
@MainActor
final class FakeAXPort: AXPort {
    var lookupResult: AXLookup = .noFrontmostApp
    /// Consumed in order by successive `readRange` calls (before, then after).
    var rangeResults: [CFRange?] = []
    var writeSelectedTextResult = false
    var writeValueSpliceResult = false

    private var rangeCallIndex = 0
    private(set) var pastedTexts: [String] = []
    private(set) var copiedOnlyTexts: [String] = []

    func lookup() -> AXLookup { lookupResult }

    func readRange(_ handle: AXElementHandle) -> CFRange? {
        guard rangeCallIndex < rangeResults.count else { return nil }
        defer { rangeCallIndex += 1 }
        return rangeResults[rangeCallIndex]
    }

    func writeSelectedText(_ handle: AXElementHandle, _ text: String) -> Bool {
        writeSelectedTextResult
    }

    func writeValueSplice(_ handle: AXElementHandle, _ text: String) -> Bool {
        writeValueSpliceResult
    }

    func paste(_ text: String) {
        pastedTexts.append(text)
    }

    func copyOnly(_ text: String) {
        copiedOnlyTexts.append(text)
    }
}

/// A handle's identity doesn't matter to `FakeAXPort` - it never inspects the
/// wrapped `AXUIElement`, only routes on configured results keyed by call order.
@MainActor
private let dummyHandle = AXElementHandle(element: AXUIElementCreateApplication(0))

@Suite(.serialized)
struct TextInjectorTests {
    @Test @MainActor
    func noFrontmostApp_copiesOnly() {
        let port = FakeAXPort()
        port.lookupResult = .noFrontmostApp

        let result = TextInjector.route("hello", port: port)

        #expect(result == .copiedToClipboard)
        #expect(port.copiedOnlyTexts == ["hello"])
        #expect(port.pastedTexts.isEmpty)
    }

    @Test @MainActor
    func noFocusedElement_pastes() {
        let port = FakeAXPort()
        port.lookupResult = .noFocusedElement

        let result = TextInjector.route("hello", port: port)

        #expect(result == .pasted)
        #expect(port.pastedTexts == ["hello"])
        #expect(port.copiedOnlyTexts.isEmpty)
    }

    @Test @MainActor
    func webArea_pastes() {
        let port = FakeAXPort()
        port.lookupResult = .element(
            AXFocusedTarget(handle: dummyHandle, role: "AXWebArea", isWebArea: true)
        )

        let result = TextInjector.route("hello", port: port)

        #expect(result == .pasted)
        #expect(port.pastedTexts == ["hello"])
    }

    @Test @MainActor
    func axWriteSucceedsAndCursorAdvances_injects() {
        let port = FakeAXPort()
        port.lookupResult = .element(
            AXFocusedTarget(handle: dummyHandle, role: "AXTextField", isWebArea: false)
        )
        port.writeSelectedTextResult = true
        let before = CFRange(location: 5, length: 0)
        let after = CFRange(location: 5 + "hi".utf16.count, length: 0)
        port.rangeResults = [before, after]

        let result = TextInjector.route("hi", port: port)

        #expect(result == .injected)
        #expect(port.pastedTexts.isEmpty)
    }

    @Test @MainActor
    func axWriteSucceedsButCursorMissing_beforeNilShortCircuitsToInjected() {
        let port = FakeAXPort()
        port.lookupResult = .element(
            AXFocusedTarget(handle: dummyHandle, role: "AXTextField", isWebArea: false)
        )
        port.writeSelectedTextResult = true
        port.rangeResults = [nil]

        let result = TextInjector.route("hi", port: port)

        #expect(result == .injected)
        #expect(port.pastedTexts.isEmpty)
    }

    @Test @MainActor
    func axWriteSucceedsButCursorStuck_fallsBackToPaste() {
        let port = FakeAXPort()
        port.lookupResult = .element(
            AXFocusedTarget(handle: dummyHandle, role: "AXTextField", isWebArea: false)
        )
        port.writeSelectedTextResult = true
        let before = CFRange(location: 5, length: 0)
        // Cursor didn't move - simulates terminals/Electron apps that silently drop AX writes.
        port.rangeResults = [before, before]

        let result = TextInjector.route("hi", port: port)

        #expect(result == .pasted)
        #expect(port.pastedTexts == ["hi"])
    }

    @Test @MainActor
    func axWriteFailsValueSpliceSucceeds_injects() {
        let port = FakeAXPort()
        port.lookupResult = .element(
            AXFocusedTarget(handle: dummyHandle, role: "AXTextField", isWebArea: false)
        )
        port.writeSelectedTextResult = false
        port.writeValueSpliceResult = true

        let result = TextInjector.route("hi", port: port)

        #expect(result == .injected)
        #expect(port.pastedTexts.isEmpty)
    }

    @Test @MainActor
    func bothWritesFail_fallsBackToPaste() {
        let port = FakeAXPort()
        port.lookupResult = .element(
            AXFocusedTarget(handle: dummyHandle, role: "AXTextField", isWebArea: false)
        )
        port.writeSelectedTextResult = false
        port.writeValueSpliceResult = false

        let result = TextInjector.route("hi", port: port)

        #expect(result == .pasted)
        #expect(port.pastedTexts == ["hi"])
    }

    // MARK: - Clipboard-manager privacy markers

    @Test @MainActor
    func copyToClipboard_marksTransientAndConcealed() {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }

        TextInjector.copyToClipboard("hi", pasteboard: pasteboard)

        #expect(pasteboard.string(forType: .string) == "hi")
        #expect(pasteboard.types?.contains(.init("org.nspasteboard.TransientType")) == true)
        #expect(pasteboard.types?.contains(.init("org.nspasteboard.ConcealedType")) == true)
    }
}
