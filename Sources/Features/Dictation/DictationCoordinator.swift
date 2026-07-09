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
    var activeMuteDeviceUID: String? { get set }
}

extension AudioCaptureManager: AudioCapturing {}
extension OverlayController: OverlayControlling {}
extension Settings: DictationSettingsProviding {}

/// Injectable abstraction for system output mute operations.
/// Uses a struct-of-closures to match the project's existing injection style.
/// Not MainActor-bound: the closures wrap nonisolated SystemAudioController HAL
/// calls and are invoked off the main actor (see DictationCoordinator.performMuteApply)
/// so a key-down does not block on blocking AudioObject*PropertyData calls.
struct MuteController: Sendable {
    var currentDeviceID: @Sendable () -> AudioDeviceID?
    var isMuted: @Sendable (AudioDeviceID) -> Bool
    var isSettable: @Sendable (AudioDeviceID) -> Bool
    var setMuted: @Sendable (Bool, AudioDeviceID) -> Void
    /// Resolve a device's stable UID, persisted so a mute can be restored even if
    /// the device's AudioDeviceID changes (BT reconnect) or disappears entirely.
    var deviceUID: @Sendable (AudioDeviceID) -> String?
    /// Resolve a persisted UID back to a current AudioDeviceID (nil if not present).
    var deviceID: @Sendable (String) -> AudioDeviceID?

    /// Default implementation wired to SystemAudioController.
    static let system = MuteController(
        currentDeviceID: { SystemAudioController.currentDefaultOutputDeviceID },
        isMuted: { SystemAudioController.isMuted(on: $0) },
        isSettable: { SystemAudioController.isMutePropertySettable(on: $0) },
        setMuted: { SystemAudioController.setMuted($0, on: $1) },
        deviceUID: { SystemAudioController.deviceUID(for: $0) },
        deviceID: { SystemAudioController.audioDeviceID(forUID: $0) }
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
    private let copyToClipboard: @MainActor (String) -> Void
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
        copyToClipboard: @escaping @MainActor (String) -> Void = { TextInjector.copyToClipboard($0) },
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
        self.copyToClipboard = copyToClipboard
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
        settings.activeMuteDeviceUID = nil
    }

    /// Recover a mute left over from a previous crash/force-quit that killed the
    /// process mid-hold. Resolves the persisted device UID so this survives that
    /// device having disappeared (or a different default output at this launch);
    /// falls back to unmuting the current default output device. Always clears the
    /// persisted record so a stale/unresolvable UID cannot wedge future launches.
    /// SIGKILL cannot be caught; launch is the only recovery path for that scenario.
    func recoverPersistedMuteOnLaunch() {
        defer { settings.activeMuteDeviceUID = nil }
        if let uid = settings.activeMuteDeviceUID, let deviceID = muteController.deviceID(uid) {
            muteController.setMuted(false, deviceID)
            return
        }
        if let deviceID = muteController.currentDeviceID() {
            muteController.setMuted(false, deviceID)
        }
    }

    /// Apply system-output mute for the current default device if the user enabled
    /// it and the device is settable. The blocking HAL calls run off the main actor
    /// (performMuteApply) so key-down handling stays snappy during device churn;
    /// the result is applied back on main only if the key is still held - a fast
    /// key-up may already have restored/no-op'd while this was in flight.
    private func applyMuteIfNeeded() {
        guard settings.muteSystemAudio else { return }
        let muteController = self.muteController
        runtimeState.muteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let result = await self.performMuteApply(muteController) else { return }
            guard self.runtimeState.keyHeld else {
                // Key released while the apply was in flight - undo any mute we just
                // applied off-main so the device does not stay muted after the hold ended.
                if !result.priorMuted {
                    muteController.setMuted(false, result.deviceID)
                }
                return
            }
            if !result.priorMuted {
                // Only record activeMute if we actually muted - don't clobber a
                // deliberate user mute (priorMuted == true means we left it alone).
                self.runtimeState.activeMute = ActiveMute(deviceID: result.deviceID, priorMuted: result.priorMuted)
                // Persist the UID (not the ID) so a crash mid-hold can be recovered
                // from at next launch even if this device disappears or its ID changes.
                self.settings.activeMuteDeviceUID = result.deviceUID
            }
        }
    }

    /// Outcome of an off-main mute apply: the targeted device and whether it was
    /// already muted before we touched it. nil (not settable) is handled by the
    /// caller reading an Optional return from performMuteApply.
    private struct MuteApplyResult: Sendable {
        let deviceID: AudioDeviceID
        let priorMuted: Bool
        let deviceUID: String?
    }

    /// Runs currentDeviceID/isSettable/isMuted/setMuted off the main actor.
    /// AudioObject*PropertyData calls block synchronously and can stall while a
    /// device is mid-transition (mirrors AudioCaptureManager's HAL-off-main
    /// pattern); doing this on main at every key-down would beachball the UI
    /// during Bluetooth churn. nonisolated so the dispatch genuinely leaves main.
    nonisolated private func performMuteApply(_ muteController: MuteController) async -> MuteApplyResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let deviceID = muteController.currentDeviceID(),
                    muteController.isSettable(deviceID)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                let priorMuted = muteController.isMuted(deviceID)
                if !priorMuted {
                    // Only mute if the user hasn't already muted - don't clobber deliberate mutes.
                    muteController.setMuted(true, deviceID)
                }
                let deviceUID = muteController.deviceUID(deviceID)
                continuation.resume(
                    returning: MuteApplyResult(deviceID: deviceID, priorMuted: priorMuted, deviceUID: deviceUID))
            }
        }
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
        runtimeState.muteTask?.cancel()
        runtimeState.muteTask = nil
        // Discard any stale pending buffer from a prior not-ready key-up - a fresh
        // session starting means we'll capture new audio from scratch.
        runtimeState.pendingSamples = nil

        runtimeState.keyDownTime = now()
        overlay.state.phase = .recording
        overlay.show()

        applyMuteIfNeeded()

        runtimeState.recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runtimeState.recordingStartTask = nil }

            do {
                try await self.audioCapture.startRecording()
            } catch is CancellationError {
                return
            } catch {
                AppLogger.audio.error("Failed to start recording: \(error)")
                // Clear keyDownTime so a following key-up sees no active session
                // and does not try to transcribe silence from a mic that never
                // started - the error overlay below is the only feedback the
                // user gets instead of the pill silently fading mid-hold.
                self.runtimeState.keyDownTime = nil
                self.overlay.showError("Microphone unavailable", duration: 2.0)
            }
        }
    }

    func handleKeyUp() {
        runtimeState.keyHeld = false
        runtimeState.recordingStartTask?.cancel()
        runtimeState.recordingStartTask = nil
        // Cancel (and clear keyHeld above) BEFORE restoreMuteIfNeeded: an
        // applyMuteIfNeeded task still in flight sees !keyHeld on its main-hop and
        // undoes its own mute, so the sync restore below and that undo can't race
        // each other into leaving the device muted.
        runtimeState.muteTask?.cancel()
        runtimeState.muteTask = nil

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
        let copyToClipboard = self.copyToClipboard
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
                let text = try await raceAgainstTimeout(transcriptionTimeout) {
                    try await engineCoordinator.transcribe(audioSamples: samples)
                }

                // Stale-session guard: a newer session has taken over.
                guard runtimeState.transcriptionGeneration == generation else { return }

                guard !Task.isCancelled, !text.isEmpty else {
                    overlay.hide()
                    return
                }

                if !hasInjectableTarget() {
                    switch settings.noFocusBehavior {
                    case .discard:
                        AppLogger.input.info("No text field and discard mode - dropping dictation without touching clipboard")
                        overlay.hide()
                        return
                    case .clipboard:
                        AppLogger.input.info("No text field and clipboard mode - copying dictation to clipboard")
                        copyToClipboard(text)
                        overlay.showInfo("Copied to clipboard", duration: 2.0)
                        return
                    }
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
                // Recover onto a fresh engine instance so the wedged one doesn't
                // eat a second concurrent transcribe (and another timeout) on the
                // next key-up. The wedged instance itself is never awaited here.
                engineCoordinator.recover()
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
        // Re-show: the engine-ready path called hideModelLoading() which scheduled an
        // orderOut at the current generation. show() bumps the generation, cancelling
        // that pending orderOut and re-displaying the window for buffered transcription.
        overlay.show()
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
        applyMuteIfNeeded()

        runtimeState.recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runtimeState.recordingStartTask = nil }
            do {
                try await self.audioCapture.startRecording()
            } catch is CancellationError {
                return
            } catch {
                AppLogger.audio.error("Failed to restart recording after device change: \(error)")
                self.runtimeState.keyDownTime = nil
                self.overlay.showError("Microphone unavailable", duration: 2.0)
            }
        }
    }

}

// MARK: - Timeout race

/// Races an unstructured transcription task against a timeout.
///
/// `withThrowingTaskGroup` cannot be used here: exiting its closure implicitly
/// awaits every child task, including the loser. A wedged CoreML call that
/// never checks cancellation would then block this function forever - exactly
/// the case the timeout exists for. Instead, `operation` runs as a detached-
/// from-structure `Task` that is left orphaned on timeout; its late result (if
/// any) is discarded by the caller's transcriptionGeneration guard.
private func raceAgainstTimeout(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> String
) async throws -> String {
    let operationTask = Task { try await operation() }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let resumeOnce = SingleResumeContinuation(continuation)

            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                resumeOnce.resume(.failure(TranscriptionError.timeout))
            }

            Task {
                do {
                    let text = try await operationTask.value
                    timeoutTask.cancel()
                    resumeOnce.resume(.success(text))
                } catch {
                    timeoutTask.cancel()
                    resumeOnce.resume(.failure(error))
                }
            }
        }
    } onCancel: {
        // Translate outer-task cancellation (e.g. handleRecordingInterrupted)
        // into a CancellationError resume via the operation's own cancellation
        // handling, rather than resuming the continuation directly here.
        operationTask.cancel()
    }
}

/// Guards a `CheckedContinuation` that can be raced to completion from
/// multiple tasks (operation success/failure, timeout, cancellation).
/// Resuming a continuation more than once is a runtime crash, so every
/// caller after the first must be a no-op.
private final class SingleResumeContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
