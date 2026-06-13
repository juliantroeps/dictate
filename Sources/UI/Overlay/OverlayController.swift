import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    let state = OverlayState()

    private var window: NSWindow?
    /// Monotonically-increasing token. Every state-mutating entry point bumps
    /// this before scheduling any deferred work. Deferred closures (asyncAfter
    /// auto-hide, fade completion) capture the post-bump value and no-op when
    /// the stored generation has advanced - i.e. a newer call has superseded them.
    private var generation = 0

    // Injectable hooks for testing (default to production behaviour).
    let scheduleAfter: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    let onOrderOut: (@MainActor () -> Void)?

    init(
        scheduleAfter: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        },
        onOrderOut: (@MainActor () -> Void)? = nil
    ) {
        self.scheduleAfter = scheduleAfter
        self.onOrderOut = onOrderOut
    }

    func show() {
        generation += 1

        if window == nil { setupWindow() }
        guard let window else { return }

        positionWindow(window)
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }
    }

    func showModelLoading() {
        state.phase = .modelLoading
        show()
    }

    func hideModelLoading() {
        guard state.phase == .modelLoading else { return }
        state.phase = .idle
        hide()
    }

    func showError(_ message: String, duration: TimeInterval = 2.0) {
        state.phase = .error(message)
        show()
        let g = generation
        scheduleAfter(duration) { [weak self] in
            guard let self, self.generation == g else { return }
            self.state.phase = .idle
            self.hide()
        }
    }

    func showInfo(_ message: String, duration: TimeInterval = 2.0) {
        state.phase = .info(message)
        show()
        let g = generation
        scheduleAfter(duration) { [weak self] in
            guard let self, self.generation == g else { return }
            self.state.phase = .idle
            self.hide()
        }
    }

    func hide() {
        state.phase = .idle
        generation += 1
        let g = generation
        guard let window else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }

        scheduleAfter(0.2) { [weak self] in
            guard let self, self.generation == g else { return }
            if let onOrderOut = self.onOrderOut {
                onOrderOut()
            } else {
                self.window?.orderOut(nil)
            }
        }
    }

    private func setupWindow() {
        let hostingView = NSHostingView(rootView: RecordingOverlayView(state: state))
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 44)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = hostingView

        self.window = window
    }

    private func positionWindow(_ window: NSWindow) {
        let targetScreen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
        guard let screen = targetScreen else { return }
        let screenFrame = screen.frame
        let windowSize = window.frame.size

        let x = screenFrame.midX - windowSize.width / 2
        let y = screenFrame.origin.y + 40

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
