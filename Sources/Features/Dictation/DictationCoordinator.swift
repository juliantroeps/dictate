import AppKit
import Foundation

protocol AudioCapturing: AnyObject, Sendable {
    var onEvent: ((AudioCaptureEvent) -> Void)? { get set }
    func startRecording() async throws
    func stopRecording() -> [Float]
}

@MainActor
protocol OverlayControlling: AnyObject {
    var state: OverlayState { get }
    func show()
    func hide()
    func showModelLoading()
    func hideModelLoading()
    func showError(_ message: String, duration: TimeInterval)
    func showInfo(_ message: String, duration: TimeInterval)
}

@MainActor
protocol DictationSettingsProviding: AnyObject {
    var minHoldDuration: Double { get }
    var muteSystemAudio: Bool { get }
    var noFocusBehavior: NoFocusBehavior { get }
}

extension AudioCaptureManager: AudioCapturing {}
extension OverlayController: OverlayControlling {}
extension Settings: DictationSettingsProviding {}

@MainActor
final class DictationCoordinator {
    private let audioCapture: any AudioCapturing
    private let overlay: any OverlayControlling
    private let engineCoordinator: any TranscriptionEngineCoordinating
    private let settings: any DictationSettingsProviding
    private let now: () -> DispatchTime
    private let transcriptionTimeout: Duration
    private let injectText: @MainActor (String) -> TextInjector.Result
    private let setMuted: (Bool) -> Void
    let runtimeState = DictationRuntimeState()

    init(
        audioCapture: any AudioCapturing = AudioCaptureManager(),
        overlay: any OverlayControlling = OverlayController(),
        engineCoordinator: any TranscriptionEngineCoordinating = EngineCoordinator(),
        settings: any DictationSettingsProviding = Settings.shared,
        now: @escaping () -> DispatchTime = DispatchTime.now,
        transcriptionTimeout: Duration = .seconds(30),
        injectText: @escaping @MainActor (String) -> TextInjector.Result = TextInjector.inject,
        setMuted: @escaping (Bool) -> Void = SystemAudioController.setMuted
    ) {
        self.audioCapture = audioCapture
        self.overlay = overlay
        self.engineCoordinator = engineCoordinator
        self.settings = settings
        self.now = now
        self.transcriptionTimeout = transcriptionTimeout
        self.injectText = injectText
        self.setMuted = setMuted
    }

    func handleAudioCaptureEvent(_ event: AudioCaptureEvent) {
        switch event {
        case .audioLevel(let level):
            runtimeState.audioLevel = level
            overlay.state.audioLevel = level
        case .recordingInterrupted:
            handleRecordingInterrupted()
        case .inputConfigurationChanged:
            break
        }
    }

    func handleKeyDown() {
        guard MicrophonePermission.isGranted else {
            overlay.showError("Microphone access denied", duration: 2.0)
            return
        }

        runtimeState.transcriptionTask?.cancel()
        runtimeState.transcriptionTask = nil
        runtimeState.recordingStartTask?.cancel()
        runtimeState.recordingStartTask = nil

        runtimeState.keyDownTime = now()
        setPhase(.recording)
        overlay.show()

        if settings.muteSystemAudio {
            setMuted(true)
        }

        runtimeState.recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runtimeState.recordingStartTask = nil }

            do {
                try await self.audioCapture.startRecording()
            } catch is CancellationError {
                return
            } catch {
                print("[dictate] Failed to start recording: \(error)")
                self.setPhase(.idle)
                self.overlay.hide()
            }
        }
    }

    func handleKeyUp() {
        runtimeState.recordingStartTask?.cancel()
        runtimeState.recordingStartTask = nil

        if settings.muteSystemAudio {
            setMuted(false)
        }

        let samples = audioCapture.stopRecording()

        guard let downTime = runtimeState.keyDownTime else {
            if case .recording = overlay.state.phase {
                setPhase(.idle)
                overlay.hide()
            }
            return
        }
        runtimeState.keyDownTime = nil

        let elapsed = Double(now().uptimeNanoseconds - downTime.uptimeNanoseconds) / 1_000_000_000
        if elapsed < settings.minHoldDuration {
            setPhase(.idle)
            overlay.hide()
            return
        }

        setPhase(.processing)
        let duration = Double(samples.count) / 16_000.0
        print("[dictate] Audio ready: \(samples.count) samples (\(String(format: "%.1f", duration))s)")

        guard engineCoordinator.isReady else {
            print("[dictate] Engine not ready, attempting preparation")
            overlay.showError("Model loading...", duration: 2.0)
            engineCoordinator.prepare(attempts: 1)
            return
        }

        let engineCoordinator = self.engineCoordinator
        let settings = self.settings
        let overlay = self.overlay
        let injectText = self.injectText
        let runtimeState = self.runtimeState
        let transcriptionTimeout = self.transcriptionTimeout
        let task = Task { @MainActor in
            defer { runtimeState.transcriptionTask = nil }

            do {
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await engineCoordinator.transcribe(audioSamples: samples)
                    }
                    group.addTask {
                        try await Task.sleep(for: transcriptionTimeout)
                        throw TranscriptionError.timeout
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }

                guard !Task.isCancelled, !text.isEmpty else {
                    setPhase(.idle)
                    overlay.hide()
                    return
                }

                let result = injectText(text)
                if settings.noFocusBehavior == .discard, result == .copiedToClipboard {
                    NSPasteboard.general.clearContents()
                }
                print("[dictate] Injected (\(result)): \(text)")
                setPhase(.idle)
                overlay.hide()
            } catch is CancellationError {
                print("[dictate] Transcription cancelled")
                setPhase(.idle)
                overlay.hide()
            } catch TranscriptionError.timeout {
                print("[dictate] Transcription timed out")
                overlay.showError("Transcription timed out", duration: 2.0)
            } catch {
                print("[dictate] Transcription failed: \(error)")
                overlay.showError("Transcription failed", duration: 2.0)
            }
        }
        runtimeState.transcriptionTask = task
    }

    func handleRecordingInterrupted() {
        if settings.muteSystemAudio {
            setMuted(false)
        }

        runtimeState.keyDownTime = nil
        runtimeState.recordingStartTask?.cancel()
        runtimeState.recordingStartTask = nil
        runtimeState.transcriptionTask?.cancel()
        runtimeState.transcriptionTask = nil
        setPhase(.idle)
        overlay.hide()
    }

    private func setPhase(_ phase: RecordingPhase) {
        runtimeState.phase = phase
        overlay.state.phase = phase
    }
}
