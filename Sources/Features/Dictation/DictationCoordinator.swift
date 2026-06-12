import AppKit
import CoreAudio
import Foundation

@MainActor
protocol AudioCapturing: AnyObject {
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

/// Injectable abstraction for system output mute operations.
/// Uses a struct-of-closures to match the project's existing injection style.
/// All closures are MainActor-bound since DictationCoordinator is MainActor.
@MainActor
struct MuteController {
    var currentDeviceID: () -> AudioDeviceID?
    var isMuted: (AudioDeviceID) -> Bool
    var isSettable: (AudioDeviceID) -> Bool
    var setMuted: (Bool, AudioDeviceID) -> Void

    /// Default implementation wired to SystemAudioController.
    static let system = MuteController(
        currentDeviceID: { SystemAudioController.currentDefaultOutputDeviceID },
        isMuted: { SystemAudioController.isMuted(on: $0) },
        isSettable: { SystemAudioController.isMutePropertySettable(on: $0) },
        setMuted: { SystemAudioController.setMuted($0, on: $1) }
    )
}

@MainActor
final class DictationCoordinator {
    private let audioCapture: any AudioCapturing
    private let overlay: any OverlayControlling
    private let engineCoordinator: any TranscriptionEngineCoordinating
    private let settings: any DictationSettingsProviding
    private let now: () -> DispatchTime
    private let transcriptionTimeout: Duration
    private let injectText: @MainActor (String) -> TextInjector.Result
    private let hasInjectableTarget: @MainActor () -> Bool
    private let muteController: MuteController
    let runtimeState: DictationRuntimeState

    init(
        audioCapture: any AudioCapturing = AudioCaptureManager(),
        overlay: any OverlayControlling = OverlayController(),
        engineCoordinator: any TranscriptionEngineCoordinating = EngineCoordinator(),
        settings: any DictationSettingsProviding = Settings.shared,
        runtimeState: DictationRuntimeState = DictationRuntimeState(),
        now: @escaping () -> DispatchTime = DispatchTime.now,
        transcriptionTimeout: Duration = .seconds(30),
        injectText: @escaping @MainActor (String) -> TextInjector.Result = TextInjector.inject,
        hasInjectableTarget: @escaping @MainActor () -> Bool = TextInjector.hasInjectableTarget,
        muteController: MuteController = .system
    ) {
        self.audioCapture = audioCapture
        self.overlay = overlay
        self.engineCoordinator = engineCoordinator
        self.settings = settings
        self.runtimeState = runtimeState
        self.now = now
        self.transcriptionTimeout = transcriptionTimeout
        self.injectText = injectText
        self.hasInjectableTarget = hasInjectableTarget
        self.muteController = muteController

        self.engineCoordinator.onReady = { [weak self] in self?.flushPendingSamples() }
        self.engineCoordinator.onLoadFailed = { [weak self] in
            guard let self else { return }
            self.runtimeState.pendingSamples = nil
            self.overlay.showError("Transcription failed", duration: 2.0)
        }
    }

    /// Restore mute to the captured prior state and clear the record.
    /// Safe to call multiple times - no-ops if no active mute is recorded.
    func restoreMuteIfNeeded() {
        guard let m = runtimeState.activeMute else { return }
        muteController.setMuted(m.priorMuted, m.deviceID)
        runtimeState.activeMute = nil
    }

    func handleAudioCaptureEvent(_ event: AudioCaptureEvent) {
        switch event {
        case .audioLevel(let level):
            runtimeState.audioLevel = level
            overlay.state.audioLevel = level
        case .recordingInterrupted(let samples):
            handleRecordingInterrupted(samples: samples)
        case .inputConfigurationChanged(let stable):
            handleInputConfigurationChanged(stable: stable)
        }
    }

    func handleKeyDown() {
        guard MicrophonePermission.isGranted else {
            overlay.showError("Microphone access denied", duration: 2.0)
            return
        }

        runtimeState.keyHeld = true
        runtimeState.transcriptionTask?.cancel()
        runtimeState.transcriptionTask = nil
        runtimeState.transcriptionGeneration += 1
        runtimeState.recordingStartTask?.cancel()
        runtimeState.recordingStartTask = nil
        // Discard any stale pending buffer from a prior not-ready key-up - a fresh
        // session starting means we'll capture new audio from scratch.
        runtimeState.pendingSamples = nil

        runtimeState.keyDownTime = now()
        overlay.state.phase = .recording
        overlay.show()

        if settings.muteSystemAudio,
           let deviceID = muteController.currentDeviceID(),
           muteController.isSettable(deviceID) {
            let priorMuted = muteController.isMuted(deviceID)
            if !priorMuted {
                // Only mute if the user hasn't already muted - don't clobber deliberate mutes.
                muteController.setMuted(true, deviceID)
                runtimeState.activeMute = ActiveMute(deviceID: deviceID, priorMuted: priorMuted)
            }
            // If already muted, leave activeMute nil - key-up will no-op correctly.
        }

        runtimeState.recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runtimeState.recordingStartTask = nil }

            do {
                try await self.audioCapture.startRecording()
            } catch is CancellationError {
                return
            } catch {
                AppLogger.audio.error("Failed to start recording: \(error)")
                self.overlay.hide()
            }
        }
    }

    func handleKeyUp() {
        runtimeState.keyHeld = false
        runtimeState.recordingStartTask?.cancel()
        runtimeState.recordingStartTask = nil

        restoreMuteIfNeeded()

        let samples = audioCapture.stopRecording()

        guard let downTime = runtimeState.keyDownTime else {
            if case .recording = overlay.state.phase {
                overlay.hide()
            }
            return
        }
        runtimeState.keyDownTime = nil

        let elapsed = Double(now().uptimeNanoseconds - downTime.uptimeNanoseconds) / 1_000_000_000
        if elapsed < settings.minHoldDuration {
            overlay.hide()
            return
        }

        overlay.state.phase = .processing
        let duration = Double(samples.count) / 16_000.0
        AppLogger.audio.info("Captured \(samples.count) samples (\(String(format: "%.1f", duration))s)")

        guard engineCoordinator.isReady else {
            AppLogger.transcription.info("Engine not ready; buffering \(samples.count) samples for flush on ready")
            runtimeState.pendingSamples = samples
            overlay.showModelLoading()
            engineCoordinator.prepare(attempts: 1)
            return
        }

        startTranscription(samples: samples, logLabel: "dictated text")
    }

    func handleRecordingInterrupted(samples: [Float]) {
        restoreMuteIfNeeded()

        runtimeState.keyDownTime = nil
        runtimeState.recordingStartTask?.cancel()
        runtimeState.recordingStartTask = nil
        runtimeState.transcriptionTask?.cancel()
        runtimeState.transcriptionTask = nil
        runtimeState.transcriptionGeneration += 1

        let minSamples = Int(settings.minHoldDuration * 16000)
        guard samples.count >= minSamples else {
            AppLogger.transcription.debug("Interrupted recording too short: \(samples.count) < \(minSamples) samples")
            overlay.hide()
            return
        }

        guard engineCoordinator.isReady else {
            AppLogger.transcription.info("Engine not ready during interruption; buffering \(samples.count) samples for flush on ready")
            runtimeState.pendingSamples = samples
            overlay.showModelLoading()
            engineCoordinator.prepare(attempts: 1)
            return
        }

        let duration = Double(samples.count) / 16_000.0
        AppLogger.audio.info("Transcribing interrupted recording: \(samples.count) samples (\(String(format: "%.1f", duration))s)")

        overlay.state.phase = .processing

        startTranscription(samples: samples, logLabel: "interrupted dictation")
    }

    /// Spawn a transcription task, guarded by a generation token so that a
    /// late-resuming cancelled task cannot stomp the phase/overlay of a newer
    /// session and cannot drop the newer session's cancel handle.
    /// Mirrors the loadGeneration pattern in EngineCoordinator.
    private func startTranscription(samples: [Float], logLabel: String) {
        runtimeState.transcriptionGeneration += 1
        let generation = runtimeState.transcriptionGeneration
        let engineCoordinator = self.engineCoordinator
        let settings = self.settings
        let overlay = self.overlay
        let injectText = self.injectText
        let hasInjectableTarget = self.hasInjectableTarget
        let runtimeState = self.runtimeState
        let transcriptionTimeout = self.transcriptionTimeout

        let task = Task { @MainActor in
            defer {
                // Only nil the handle when no newer session replaced it.
                if runtimeState.transcriptionGeneration == generation {
                    runtimeState.transcriptionTask = nil
                }
            }

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

                // Stale-session guard: a newer session has taken over.
                guard runtimeState.transcriptionGeneration == generation else { return }

                guard !Task.isCancelled, !text.isEmpty else {
                    overlay.hide()
                    return
                }

                if settings.noFocusBehavior == .discard, !hasInjectableTarget() {
                    AppLogger.input.info("No text field and discard mode - dropping dictation without touching clipboard")
                    overlay.hide()
                    return
                }

                let result = injectText(text)
                AppLogger.input.info("Injected \(logLabel) using \(result)")
                overlay.hide()
            } catch is CancellationError {
                AppLogger.transcription.info("\(logLabel) cancelled")
                guard runtimeState.transcriptionGeneration == generation else { return }
                overlay.hide()
            } catch TranscriptionError.timeout {
                AppLogger.transcription.warning("\(logLabel) timed out")
                guard runtimeState.transcriptionGeneration == generation else { return }
                overlay.showError("Transcription timed out", duration: 2.0)
            } catch {
                AppLogger.transcription.error("\(logLabel) failed: \(error)")
                guard runtimeState.transcriptionGeneration == generation else { return }
                overlay.showError("Transcription failed", duration: 2.0)
            }
        }
        runtimeState.transcriptionTask = task
    }

    private func flushPendingSamples() {
        guard let samples = runtimeState.pendingSamples else { return }
        runtimeState.pendingSamples = nil
        overlay.state.phase = .processing
        startTranscription(samples: samples, logLabel: "buffered dictation")
    }

    private func handleInputConfigurationChanged(stable: Bool) {
        // Only re-arm if the user is still holding the key after a mid-hold
        // device change. keyDownTime was cleared on interruption, so restore it
        // (using current time) and restart capture on the new device for the
        // remainder of the utterance. Unstable formats: skip - the next stable
        // event will retry.
        guard runtimeState.keyHeld, stable else { return }
        guard MicrophonePermission.isGranted else { return }

        // Avoid double-arming if a start is already in flight.
        guard runtimeState.recordingStartTask == nil else { return }

        runtimeState.keyDownTime = now()
        overlay.state.phase = .recording
        overlay.show()

        runtimeState.recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runtimeState.recordingStartTask = nil }
            do {
                try await self.audioCapture.startRecording()
            } catch is CancellationError {
                return
            } catch {
                AppLogger.audio.error("Failed to restart recording after device change: \(error)")
                self.overlay.hide()
            }
        }
    }

}
