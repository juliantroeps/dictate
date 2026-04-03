import Foundation

@testable import dictate

@MainActor
final class FakeDictationSettings: DictationSettingsProviding {
    var minHoldDuration: Double = 0.4
    var muteSystemAudio: Bool = false
    var noFocusBehavior: NoFocusBehavior = .clipboard
}

final class FakeAudioCaptureManager: AudioCapturing, @unchecked Sendable {
    var onAudioLevel: ((Float) -> Void)?
    var onRecordingInterrupted: (() -> Void)?
    var startRecordingCalls = 0
    var stopRecordingCalls = 0
    var capturedSamples: [Float] = [0.1, 0.2, 0.3]
    var startRecordingError: Error?
    var startRecordingDelay: Duration?

    func startRecording() async throws {
        startRecordingCalls += 1
        if let delay = startRecordingDelay {
            try await Task.sleep(for: delay)
        }
        if let error = startRecordingError {
            throw error
        }
    }

    func stopRecording() -> [Float] {
        stopRecordingCalls += 1
        return capturedSamples
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
}

@MainActor
final class MutingRecorder {
    private(set) var values: [Bool] = []

    func setMuted(_ muted: Bool) {
        values.append(muted)
    }
}
