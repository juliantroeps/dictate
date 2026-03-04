import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let keyListener = KeyListener()
    private let audioCapture = AudioCaptureManager()
    private let overlay = OverlayController()
    private let engine: TranscriptionEngine = WhisperKitEngine()
    private var permissionTimer: Timer?
    private var keyDownTime: DispatchTime?
    private var transcriptionTask: Task<Void, Never>?

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

        MicrophonePermission.requestInBackground()

        Task {
            do {
                try await engine.prepare()
            } catch {
                print("[dikt] Engine setup failed: \(error)")
            }
        }

        audioCapture.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.overlay.state.audioLevel = level
            }
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

        transcriptionTask?.cancel()
        transcriptionTask = nil

        keyDownTime = .now()
        overlay.state.phase = .recording
        overlay.show()

        SystemAudioController.setMuted(true)
        do {
            try audioCapture.startRecording()
        } catch {
            print("[dikt] Failed to start recording: \(error)")
            overlay.state.phase = .idle
            overlay.hide()
        }
    }

    private func handleKeyUp() {
        SystemAudioController.setMuted(false)
        let samples = audioCapture.stopRecording()

        guard let downTime = keyDownTime else { return }
        keyDownTime = nil

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - downTime.uptimeNanoseconds) / 1_000_000_000

        if elapsed < minHoldDuration {
            overlay.state.phase = .idle
            overlay.hide()
            return
        }

        overlay.state.phase = .processing

        let duration = Double(samples.count) / 16_000.0
        print("[dikt] Audio ready: \(samples.count) samples (\(String(format: "%.1f", duration))s)")

        guard engine.isReady else {
            print("[dikt] Engine not ready, discarding audio")
            overlay.state.phase = .idle
            overlay.hide()
            return
        }

        transcriptionTask = Task {
            defer {
                if !Task.isCancelled {
                    overlay.state.phase = .idle
                    overlay.hide()
                }
            }
            do {
                let text = try await engine.transcribe(audioSamples: samples)
                guard !Task.isCancelled else { return }
                print("[dikt] Transcription: \(text)")
            } catch is CancellationError {
                print("[dikt] Transcription cancelled")
            } catch {
                print("[dikt] Transcription failed: \(error)")
            }
        }
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
