import CoreAudio
import Foundation

@testable import dictate

@MainActor
final class FakeDictationSettings: DictationSettingsProviding {
    var minHoldDuration: Double = 0.4
    var muteSystemAudio: Bool = false
    var noFocusBehavior: NoFocusBehavior = .clipboard
}

@MainActor
final class FakeAudioCaptureManager: AudioCapturing {
    var onEvent: ((AudioCaptureEvent) -> Void)?
    var startRecordingCalls = 0
    var stopRecordingCalls = 0
    var capturedSamples: [Float] = [0.1, 0.2, 0.3]
    var startRecordingError: Error?
    var startRecordingDelay: Duration?
    /// True once startRecording() returns without throwing, false once stopRecording() is called.
    /// Mirrors the fixed AudioCaptureManager's isRecording invariant for the hot-mic regression test.
    private(set) var isRecordingAfterStart = false

    func startRecording() async throws {
        startRecordingCalls += 1
        if let delay = startRecordingDelay {
            // Check cancellation after the delay to mirror the fixed manager's behaviour:
            // a cancel arriving during a slow start must not set isRecordingAfterStart = true.
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
        }
        if let error = startRecordingError {
            throw error
        }
        isRecordingAfterStart = true
    }

    func stopRecording() -> [Float] {
        stopRecordingCalls += 1
        isRecordingAfterStart = false
        return capturedSamples
    }

    func send(_ event: AudioCaptureEvent) {
        onEvent?(event)
    }
}

@MainActor
final class FakeOverlayController: OverlayControlling {
    let state = OverlayState()
    private(set) var shownErrors: [String] = []
    private(set) var shownInfos: [String] = []
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var modelLoadingShown = 0
    private(set) var modelLoadingHidden = 0

    func show() {
        showCount += 1
    }

    func hide() {
        hideCount += 1
        state.phase = .idle
    }

    func showModelLoading() {
        modelLoadingShown += 1
        state.phase = .modelLoading
    }

    func hideModelLoading() {
        modelLoadingHidden += 1
        if case .modelLoading = state.phase {
            state.phase = .idle
        }
    }

    func showError(_ message: String, duration _: TimeInterval) {
        shownErrors.append(message)
        state.phase = .error(message)
    }

    func showInfo(_ message: String, duration _: TimeInterval) {
        shownInfos.append(message)
        state.phase = .info(message)
    }
}

@MainActor
final class FakeTranscriptionEngineCoordinator: TranscriptionEngineCoordinating {
    var isReady = true
    var onReady: (@MainActor () -> Void)?
    var onLoadFailed: (@MainActor () -> Void)?
    private(set) var prepareAttempts: [Int] = []
    private(set) var reloadModels: [String] = []
    private(set) var transcribeInputs: [[Float]] = []
    var transcribeBehavior: (([Float]) async throws -> String)?

    func prepare(attempts: Int) {
        prepareAttempts.append(attempts)
    }

    func reload(using model: String) {
        reloadModels.append(model)
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        transcribeInputs.append(audioSamples)
        if let transcribeBehavior {
            return try await transcribeBehavior(audioSamples)
        }
        return "transcribed text"
    }

    func unload() {}

    /// Simulate the engine becoming ready and fire the onReady callback.
    func becomeReady() {
        isReady = true
        onReady?()
    }

    /// Simulate a load failure and fire the onLoadFailed callback.
    func failLoad() {
        isReady = false
        onLoadFailed?()
    }
}

/// Test double for MuteController - tracks calls and supports per-device state.
@MainActor
final class FakeMuteController {
    var currentDevice: AudioDeviceID? = 1
    /// Current mute state per device. Starts unmuted by default.
    var mutedState: [AudioDeviceID: Bool] = [:]
    /// Set of device IDs where mute is settable.
    var settable: Set<AudioDeviceID> = [1]
    /// Ordered log of (muted, deviceID) calls to setMuted.
    private(set) var calls: [(muted: Bool, device: AudioDeviceID)] = []

    func makeController() -> MuteController {
        MuteController(
            currentDeviceID: { [unowned self] in self.currentDevice },
            isMuted: { [unowned self] id in self.mutedState[id] ?? false },
            isSettable: { [unowned self] id in self.settable.contains(id) },
            setMuted: { [unowned self] muted, id in
                self.calls.append((muted: muted, device: id))
                self.mutedState[id] = muted
            }
        )
    }
}
