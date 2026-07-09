import Foundation

@testable import dictate

/// Controllable stand-in for `WhisperKitEngine`, used to drive
/// `EngineCoordinator` through success/failure/delay scenarios without
/// touching CoreML. `@unchecked Sendable` + lock-guarded, mirroring the
/// nonisolated(unsafe)+lock idiom `WhisperKitEngine.isReady` itself uses.
final class FakeTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "FakeEngine"
    let model: String

    private let lock = NSLock()
    private var _isReady = false
    var isReady: Bool { lock.withLock { _isReady } }

    /// Outcome for prepare(); defaults to instant success.
    var prepareBehavior: (@Sendable () async throws -> Void)?
    var prepareDelay: Duration?
    private(set) var prepareCallCount = 0
    private(set) var unloadCallCount = 0

    init(model: String = "test-model") {
        self.model = model
    }

    func prepare() async throws {
        lock.withLock { prepareCallCount += 1 }
        if let prepareDelay {
            try await Task.sleep(for: prepareDelay)
        }
        try await prepareBehavior?()
        lock.withLock { _isReady = true }
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        "fake transcription"
    }

    func unload() async {
        lock.withLock {
            unloadCallCount += 1
            _isReady = false
        }
    }
}

@MainActor
final class FakeEngineSettings: EngineSettingsManaging {
    var whisperModel: String

    init(whisperModel: String = "test-model") {
        self.whisperModel = whisperModel
    }
}

/// Resumes a waiting test once EngineCoordinator's async load flow reaches a
/// terminal state (onReady/onLoadFailed). Those callbacks are the only
/// observable completion signal for the coordinator's internal load task.
@MainActor
final class LoadCompletion {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didFire = false

    func fire() {
        didFire = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if didFire { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
