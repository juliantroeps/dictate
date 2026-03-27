import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let keyListener = KeyListener()
    private let audioCapture = AudioCaptureManager()
    private let overlay = OverlayController()
    private let settings = Settings.shared
    private var engine: TranscriptionEngine
    private var permissionTimer: Timer?
    private var keyDownTime: DispatchTime?
    private var transcriptionTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var engineLoadTask: Task<Void, Never>?
    private var eventMonitor: Any?

    override init() {
        self.engine = WhisperKitEngine(model: Settings.shared.whisperModel)
        super.init()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioCapture.cleanup()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "dictate")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.contentViewController = NSHostingController(rootView: SettingsView())
        popover.behavior = .transient

        AccessibilityPermission.requestIfNeeded()

        MicrophonePermission.requestInBackground()

        prepareEngine()

        observeModelChange()

        audioCapture.onRecordingInterrupted = { [weak self] in
            DispatchQueue.main.async {
                self?.handleRecordingInterrupted()
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
            overlay.showError("Microphone access denied")
            return
        }

        transcriptionTask?.cancel()
        transcriptionTask = nil

        keyDownTime = .now()
        overlay.state.phase = .recording
        overlay.show()

        if settings.muteSystemAudio { SystemAudioController.setMuted(true) }
        recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.audioCapture.startRecording()
            } catch is CancellationError {
                // key released before recording started - handleKeyUp already cleans up
            } catch {
                print("[dictate] Failed to start recording: \(error)")
                self.overlay.state.phase = .idle
                self.overlay.hide()
            }
        }
    }

    private func handleKeyUp() {
        recordingStartTask?.cancel()
        recordingStartTask = nil
        if settings.muteSystemAudio { SystemAudioController.setMuted(false) }
        let samples = audioCapture.stopRecording()

        guard let downTime = keyDownTime else { return }
        keyDownTime = nil

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - downTime.uptimeNanoseconds) / 1_000_000_000

        if elapsed < settings.minHoldDuration {
            overlay.state.phase = .idle
            overlay.hide()
            return
        }

        overlay.state.phase = .processing

        let duration = Double(samples.count) / 16_000.0
        print("[dictate] Audio ready: \(samples.count) samples (\(String(format: "%.1f", duration))s)")

        guard engine.isReady else {
            print("[dictate] Engine not ready, attempting preparation")
            overlay.showError("Model loading...")
            prepareEngine(attempts: 1)
            return
        }

        transcriptionTask = Task {
            do {
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await self.engine.transcribe(audioSamples: samples)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(30))
                        throw TranscriptionError.timeout
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                guard !Task.isCancelled, !text.isEmpty else {
                    overlay.state.phase = .idle
                    overlay.hide()
                    return
                }
                let result = TextInjector.inject(text)
                if settings.noFocusBehavior == .discard && result == .copiedToClipboard {
                    NSPasteboard.general.clearContents()
                }
                print("[dictate] Injected (\(result)): \(text)")
                overlay.state.phase = .idle
                overlay.hide()
            } catch is CancellationError {
                print("[dictate] Transcription cancelled")
                overlay.state.phase = .idle
                overlay.hide()
            } catch TranscriptionError.timeout {
                print("[dictate] Transcription timed out")
                overlay.showError("Transcription timed out")
            } catch {
                print("[dictate] Transcription failed: \(error)")
                overlay.showError("Transcription failed")
            }
        }
    }

    private func observeModelChange() {
        withObservationTracking {
            _ = settings.whisperModel
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reloadEngine()
                self?.observeModelChange()
            }
        }
    }

    private func handleRecordingInterrupted() {
        if settings.muteSystemAudio { SystemAudioController.setMuted(false) }
        keyDownTime = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        overlay.showError("Audio device disconnected")
    }

    private func prepareEngine(attempts: Int = 3) {
        engineLoadTask = Task {
            // Suppress pill if model loads quickly (cached case)
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            if !engine.isReady {
                overlay.showModelLoading()
            }

            for attempt in 1...attempts {
                do {
                    try await engine.prepare()
                    guard !Task.isCancelled else {
                        overlay.hideModelLoading()
                        return
                    }
                    settings.engineState = .ready
                    overlay.hideModelLoading()
                    return
                } catch is CancellationError {
                    overlay.hideModelLoading()
                    return
                } catch {
                    print("[dictate] Engine setup attempt \(attempt)/\(attempts) failed: \(error)")
                    if attempt < attempts {
                        try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                    }
                }
            }
            settings.engineState = .failed
            overlay.hideModelLoading()
            print("[dictate] Engine setup failed after \(attempts) attempts")
        }
    }

    private func reloadEngine() {
        engineLoadTask?.cancel()
        engine.unload()
        settings.engineState = .loading
        engine = WhisperKitEngine(model: settings.whisperModel)
        overlay.showModelLoading()
        engineLoadTask = Task {
            do {
                try await engine.prepare()
                guard !Task.isCancelled else {
                    overlay.hideModelLoading()
                    return
                }
                settings.engineState = .ready
                overlay.hideModelLoading()
            } catch is CancellationError {
                overlay.hideModelLoading()
            } catch {
                settings.engineState = .failed
                overlay.hideModelLoading()
                print("[dictate] Engine reload failed: \(error)")
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
