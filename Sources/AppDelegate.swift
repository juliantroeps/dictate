import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let keyListener = KeyListener()
    private let audioCapture = AudioCaptureManager()
    private var permissionTimer: Timer?
    private var keyDownTime: DispatchTime?

    private let minHoldDuration: Double = 0.3

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "dikt")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.contentViewController = NSHostingController(rootView: SettingsView())
        popover.behavior = .transient

        AccessibilityPermission.requestIfNeeded()

        Task {
            let granted = await MicrophonePermission.request()
            print("[dikt] Microphone permission: \(granted)")
        }

        keyListener.onKeyDown = { [weak self] in
            self?.handleKeyDown()
        }
        keyListener.onKeyUp = { [weak self] in
            self?.handleKeyUp()
        }

        if AccessibilityPermission.isGranted {
            _ = keyListener.start()
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if AccessibilityPermission.isGranted {
                        self.permissionTimer?.invalidate()
                        self.permissionTimer = nil
                        _ = self.keyListener.start()
                    }
                }
            }
        }
    }

    private func handleKeyDown() {
        guard MicrophonePermission.isGranted else {
            print("[dikt] Microphone permission not granted")
            return
        }

        SystemAudioController.setMuted(true)
        keyDownTime = .now()
        do {
            try audioCapture.startRecording()
        } catch {
            print("[dikt] Failed to start recording: \(error)")
        }
    }

    private func handleKeyUp() {
        SystemAudioController.setMuted(false)
        let samples = audioCapture.stopRecording()

        guard let downTime = keyDownTime else { return }
        keyDownTime = nil

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - downTime.uptimeNanoseconds) / 1_000_000_000

        if elapsed < minHoldDuration {
            print("[dikt] Discarded — too short (\(String(format: "%.0f", elapsed * 1000))ms)")
            return
        }

        let duration = Double(samples.count) / 16_000.0
        print("[dikt] Audio ready: \(samples.count) samples (\(String(format: "%.1f", duration))s)")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
