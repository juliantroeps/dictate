import AppKit
import Testing

@testable import dictate

/// Real private named pasteboards; a `string(forType:)` read stands in for a consumer
/// read and fires the lazy provider. Durations are injected short. Every started task
/// is awaited, and restores are slept past, before the board is released.
@Suite(.serialized)
struct PasteReceiptTests {
    private static let grace: Duration = .milliseconds(30)
    private static let timeout: Duration = .milliseconds(200)
    private static let pastGrace: Duration = .milliseconds(300)

    @Test @MainActor
    func consumerRead_firesProvider() async {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }

        let receipt = PasteReceipt(text: "DICT")
        _ = receipt.write(to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "DICT")
        #expect(await receipt.waitForRead(timeout: Self.timeout))
        #expect(receipt.hasBeenRead)
    }

    @Test @MainActor
    func fulfillment_doesNotBumpChangeCount() {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }

        let receipt = PasteReceipt(text: "DICT")
        let count = receipt.write(to: pasteboard)
        #expect(pasteboard.changeCount == count)

        _ = pasteboard.string(forType: .string)

        #expect(receipt.hasBeenRead)
        #expect(pasteboard.changeCount == count)
    }

    @Test @MainActor
    func markers_areEager() {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }

        let receipt = PasteReceipt(text: "DICT")
        _ = receipt.write(to: pasteboard)

        let types = pasteboard.types ?? []
        #expect(types.contains(TextInjector.transientType))
        #expect(types.contains(TextInjector.concealedType))

        _ = pasteboard.data(forType: TextInjector.transientType)
        _ = pasteboard.data(forType: TextInjector.concealedType)
        #expect(!receipt.hasBeenRead)
    }

    @Test @MainActor
    func consumed_restoresAfterGrace() async {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("ORIG", forType: .string)

        let consumed = await TextInjector.pasteWithReceipt(
            "DICT",
            pasteboard: pasteboard,
            sendPaste: { _ = pasteboard.string(forType: .string) },
            grace: Self.grace,
            timeout: Self.timeout
        )
        try? await Task.sleep(for: Self.pastGrace)

        #expect(consumed)
        #expect(pasteboard.string(forType: .string) == "ORIG")
        #expect(!TextInjector.hasOutstandingReceipt(on: pasteboard))
    }

    @Test @MainActor
    func notConsumed_keepsPlainString() async {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("ORIG", forType: .string)

        // Counted inside sendPaste (right after the write): a later advance means the
        // board was rewritten, i.e. the promise was replaced by a plain string.
        var countAfterWrite = 0
        let consumed = await TextInjector.pasteWithReceipt(
            "DICT",
            pasteboard: pasteboard,
            sendPaste: { countAfterWrite = pasteboard.changeCount },
            grace: Self.grace,
            timeout: Self.timeout
        )

        #expect(!consumed)
        #expect(pasteboard.changeCount > countAfterWrite)
        #expect(pasteboard.string(forType: .string) == "DICT")
        let types = pasteboard.types ?? []
        #expect(types.contains(TextInjector.transientType))
        #expect(types.contains(TextInjector.concealedType))
        #expect(!TextInjector.hasOutstandingReceipt(on: pasteboard))
    }

    @Test @MainActor
    func clipboardMovedOn_leavesIt() async {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("ORIG", forType: .string)

        let consumed = await TextInjector.pasteWithReceipt(
            "DICT",
            pasteboard: pasteboard,
            sendPaste: {
                pasteboard.clearContents()
                pasteboard.setString("NEWCOPY", forType: .string)
            },
            grace: Self.grace,
            timeout: Self.timeout
        )
        try? await Task.sleep(for: Self.pastGrace)

        #expect(consumed)
        #expect(pasteboard.string(forType: .string) == "NEWCOPY")
        #expect(!(pasteboard.types ?? []).contains(TextInjector.transientType))
        #expect(!TextInjector.hasOutstandingReceipt(on: pasteboard))
    }

    @Test @MainActor
    func cancelledCaller_stillSettles() async {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("ORIG", forType: .string)

        var countAfterWrite = 0
        let caller = Task { @MainActor in
            await TextInjector.pasteWithReceipt(
                "DICT",
                pasteboard: pasteboard,
                sendPaste: { countAfterWrite = pasteboard.changeCount },
                grace: Self.grace,
                timeout: Self.timeout
            )
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(TextInjector.hasOutstandingReceipt(on: pasteboard))

        caller.cancel()
        let consumed = await caller.value

        // Settled as a plain string, not left as an outstanding promise.
        #expect(!consumed)
        #expect(pasteboard.changeCount > countAfterWrite)
        #expect(pasteboard.string(forType: .string) == "DICT")
        #expect(!TextInjector.hasOutstandingReceipt(on: pasteboard))
    }

    @Test @MainActor
    func overlappingPaste_settlesOlderFirst() async {
        let pasteboard = NSPasteboard(name: .init("dikt.test.\(#function)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("ORIG", forType: .string)

        let longTimeout: Duration = .seconds(2)
        let older = TextInjector.startReceiptPaste(
            "A", pasteboard: pasteboard, sendPaste: {}, grace: Self.grace, timeout: longTimeout)
        #expect(TextInjector.hasOutstandingReceipt(on: pasteboard))

        // B starts inside A's window: A must be settled (plain string) before B snapshots.
        let newer = TextInjector.startReceiptPaste(
            "B",
            pasteboard: pasteboard,
            sendPaste: { _ = pasteboard.string(forType: .string) },
            grace: Self.grace,
            timeout: longTimeout
        )

        let olderConsumed = await older.value
        let newerConsumed = await newer.value
        try? await Task.sleep(for: Self.pastGrace)

        // A's provider never fired (it would have latched a read), B's own receipt works,
        // and B's snapshot was A's plain text.
        #expect(!olderConsumed)
        #expect(newerConsumed)
        #expect(pasteboard.string(forType: .string) == "A")
        #expect(!TextInjector.hasOutstandingReceipt(on: pasteboard))
    }

    @Test @MainActor
    func settleOutstanding_ignoresOtherPasteboards() async {
        let board = NSPasteboard(name: .init("dikt.test.\(#function).a"))
        let other = NSPasteboard(name: .init("dikt.test.\(#function).b"))
        defer {
            board.releaseGlobally()
            other.releaseGlobally()
        }

        let task = TextInjector.startReceiptPaste(
            "DICT", pasteboard: board, sendPaste: {}, grace: Self.grace, timeout: Self.timeout)
        TextInjector.settleOutstanding(on: other)
        #expect(TextInjector.hasOutstandingReceipt(on: board))

        let consumed = await task.value

        #expect(!consumed)
        #expect(!TextInjector.hasOutstandingReceipt(on: board))
    }
}
