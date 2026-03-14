import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    let state = OverlayState()

    private var window: NSWindow?

    func show() {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard case .error = self?.state.phase else { return }
            self?.state.phase = .idle
            self?.hide()
        }
    }

    func hide() {
        guard let window else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.window?.orderOut(nil)
            }
        })
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
