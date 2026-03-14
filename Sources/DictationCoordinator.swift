import AppKit

@MainActor
final class DictationCoordinator {
    private let audioCapture = AudioCaptureManager()
    private let overlay = OverlayController()
    private let engineManager: EngineManager
    private let settings = Settings.shared

    private var keyDownTime: DispatchTime?
    private var transcriptionTask: Task<Void, Never>?

    init(engineManager: EngineManager) {
        self.engineManager = engineManager

        engineManager.onLoadingStateChanged = { [weak self] loading in
            if loading {
                self?.overlay.showModelLoading()
            } else {
                self?.overlay.hideModelLoading()
            }
        }

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
    }

    func handleKeyDown() {
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
        do {
            try audioCapture.startRecording()
        } catch {
            print("[dictate] Failed to start recording: \(error)")
            if settings.muteSystemAudio { SystemAudioController.setMuted(false) }
            overlay.state.phase = .idle
            overlay.hide()
        }
    }

    func handleKeyUp() {
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

        guard engineManager.isReady else {
            print("[dictate] Engine not ready, attempting preparation")
            overlay.showError("Model loading...")
            engineManager.prepare(attempts: 1)
            return
        }

        let engine = engineManager.engine
        transcriptionTask = Task {
            do {
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await engine.transcribe(audioSamples: samples)
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

    private func handleRecordingInterrupted() {
        if settings.muteSystemAudio { SystemAudioController.setMuted(false) }
        keyDownTime = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        overlay.showError("Audio device disconnected")
    }
}
