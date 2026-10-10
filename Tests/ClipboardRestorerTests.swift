import AppKit
import Testing

@testable import dictate

@Suite(.serialized)
struct ClipboardRestorerTests {
    @Test @MainActor
    func restoresPriorContentsWhenUnchanged() async {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("ORIG", forType: .string)

        // Constructed before overwriting, mirroring the receipt paste's ordering.
        let restorer = ClipboardRestorer(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("DICT", forType: .string)

        restorer.restore(after: .milliseconds(30))
        try? await Task.sleep(for: .milliseconds(1500))

        #expect(pasteboard.string(forType: .string) == "ORIG")
    }

    @Test @MainActor
    func skipsRestoreWhenClipboardChangedSinceWrite() async {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("ORIG", forType: .string)

        let restorer = ClipboardRestorer(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("DICT", forType: .string)

        restorer.restore(after: .milliseconds(30))

        // A concurrent copy lands before the restore delay elapses - must not be clobbered.
        pasteboard.clearContents()
        pasteboard.setString("NEWCOPY", forType: .string)

        try? await Task.sleep(for: .milliseconds(1500))

        #expect(pasteboard.string(forType: .string) == "NEWCOPY")
    }

    @Test @MainActor
    func restoresWhenCountBumpedButOurTextStillOnTop() async {
        // Browsers / clipboard managers bump changeCount while handling the paste even
        // though the dictation is still on top - restore must still fire.
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("ORIG", forType: .string)

        let restorer = ClipboardRestorer(pasteboard: pasteboard, writtenText: "DICT")

        pasteboard.clearContents()
        pasteboard.setString("DICT", forType: .string)

        restorer.restore(after: .milliseconds(30))

        // Same DICT re-written (bumps changeCount, top string unchanged).
        pasteboard.clearContents()
        pasteboard.setString("DICT", forType: .string)

        try? await Task.sleep(for: .milliseconds(1500))

        #expect(pasteboard.string(forType: .string) == "ORIG")
    }

    @Test @MainActor
    func laterPromiseDuringGrace_isNotFiredByOlderRestore() async {
        // Receipt A was consumed and its grace restore is pending; the next dictation B
        // starts inside that window. A's restore must not read B's lazy `.string`: that
        // would fire B's provider and fake a receipt (B restores early, consumer pastes
        // the wrong text).
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("ORIG", forType: .string)
        let older = ClipboardRestorer(pasteboard: pasteboard, writtenText: "A")
        pasteboard.clearContents()
        pasteboard.setString("A", forType: .string)
        older.restore(after: .milliseconds(30))

        let newer = TextInjector.startReceiptPaste(
            "B",
            pasteboard: pasteboard,
            sendPaste: {},
            grace: .milliseconds(30),
            timeout: .milliseconds(300)
        )
        // Resolves at B's timeout, well after the older restore woke.
        let consumed = await newer.value

        #expect(!consumed)
        #expect(pasteboard.string(forType: .string) == "B")
    }

    @Test @MainActor
    func unchangedCount_restoresWithoutReadingString() async {
        // Count unchanged means the board is still as left: restore, and never read
        // `.string` (it would fire a lazy promise sitting there).
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("ORIG", forType: .string)
        let restorer = ClipboardRestorer(pasteboard: pasteboard, writtenText: "DICT")

        let promise = PasteReceipt(text: "DICT")
        _ = promise.write(to: pasteboard)

        restorer.restore(after: .milliseconds(30))
        try? await Task.sleep(for: .milliseconds(300))

        // Read flag first: our own `.string` read below would fire the provider.
        #expect(!promise.hasBeenRead)
        #expect(pasteboard.string(forType: .string) == "ORIG")
    }

    @Test @MainActor
    func emptySavedItemsClearsInsteadOfWriting() async {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }

        // Nothing on the pasteboard when the restorer is created.
        pasteboard.clearContents()
        let restorer = ClipboardRestorer(pasteboard: pasteboard)

        pasteboard.setString("DICT", forType: .string)

        restorer.restore(after: .milliseconds(30))
        try? await Task.sleep(for: .milliseconds(1500))

        #expect(pasteboard.string(forType: .string) == nil)
    }
}
