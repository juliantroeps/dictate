import AppKit
import Foundation

/// Pasteboard promise for one dictation paste. The `.string` flavor is lazy: the
/// text only materializes when a consumer reads it, and that read is the receipt that
/// the paste landed. The transient/concealed markers are eager, so clipboard managers
/// that honor nspasteboard.org can skip the entry by checking types without reading
/// the string (which would otherwise fake a receipt).
///
/// Provider callbacks are nonisolated and serviced on the main run loop: state lives
/// under a lock and nothing here blocks the main thread. The outcome latches (first of
/// read or abandon wins) so a read that lands before anyone awaits is not missed.
final class PasteReceipt: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private enum Outcome {
        case pending
        case read(ContinuousClock.Instant)
        case abandoned
    }

    private let text: String
    private let lock = NSLock()
    private var outcome = Outcome.pending
    private var waiter: CheckedContinuation<Bool, Never>?

    init(text: String) {
        self.text = text
        super.init()
    }

    /// When the provider fired, nil if it never did.
    var readInstant: ContinuousClock.Instant? {
        lock.withLock {
            if case .read(let instant) = outcome { return instant }
            return nil
        }
    }

    var hasBeenRead: Bool { readInstant != nil }

    /// True once `abandon()` won the race against a read: the pasteboard no longer
    /// holds this promise and a settle step must not act on it again.
    var isAbandoned: Bool {
        lock.withLock {
            if case .abandoned = outcome { return true }
            return false
        }
    }

    /// One item: `.string` lazy (this object), markers eager. Returns the pasteboard
    /// `changeCount` after the write. The pasteboard retains the item (and this
    /// provider) while the promise is on the board.
    @MainActor
    func write(to pasteboard: NSPasteboard) -> Int {
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        item.setData(Data(), forType: TextInjector.transientType)
        item.setData(Data(), forType: TextInjector.concealedType)

        pasteboard.clearContents()
        if !pasteboard.writeObjects([item]) {
            AppLogger.input.warning("Paste receipt write failed")
        }
        return pasteboard.changeCount
    }

    /// true if the provider fired. Latched: a read before this call still counts.
    /// Resolves false on timeout or `abandon()`; a read after a timeout is still
    /// visible through `hasBeenRead`.
    func waitForRead(timeout: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let immediate: Bool? = lock.withLock {
                switch outcome {
                case .read: return true
                case .abandoned: return false
                case .pending:
                    waiter = continuation
                    return nil
                }
            }
            if let immediate {
                continuation.resume(returning: immediate)
                return
            }
            // Unstructured on purpose: the caller being cancelled must not cut the wait short.
            Task {
                try? await Task.sleep(for: timeout)
                resolveWaiter(false)
            }
        }
    }

    /// Resolves a pending `waitForRead` as false now and latches, so a later
    /// `waitForRead` also returns false. No-op once a read has been recorded.
    func abandon() {
        let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
            if case .pending = outcome { outcome = .abandoned }
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(returning: false)
    }

    private func resolveWaiter(_ value: Bool) {
        let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(returning: value)
    }

    // MARK: - NSPasteboardItemDataProvider

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .string else { return }
        item.setString(text, forType: type)

        let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard case .pending = outcome else { return nil }
            outcome = .read(.now)
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(returning: true)
    }
}
