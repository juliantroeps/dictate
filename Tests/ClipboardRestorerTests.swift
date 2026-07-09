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

        // Constructed before overwriting, mirroring pasteViaClipboard's ordering.
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
