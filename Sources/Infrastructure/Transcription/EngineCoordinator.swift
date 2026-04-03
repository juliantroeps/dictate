import Foundation

@MainActor
protocol EngineSettingsManaging: AnyObject {
    var whisperModel: String { get }
}

@MainActor
protocol TranscriptionEngineCoordinating: AnyObject, Sendable {
    var isReady: Bool { get }
    func prepare(attempts: Int)
    func reload(using model: String)
    func transcribe(audioSamples: [Float]) async throws -> String
    func unload()
}

extension Settings: EngineSettingsManaging {}

@MainActor
final class EngineCoordinator: TranscriptionEngineCoordinating {
    private let settings: any EngineSettingsManaging
    private let overlay: any OverlayControlling
    private let runtimeState: DictationRuntimeState
    private var engine: TranscriptionEngine
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: Int = 0

    var isReady: Bool { engine.isReady }

    init(
        settings: any EngineSettingsManaging = Settings.shared,
        overlay: any OverlayControlling = OverlayController(),
        runtimeState: DictationRuntimeState = DictationRuntimeState(),
        engine: TranscriptionEngine? = nil
    ) {
        self.settings = settings
        self.overlay = overlay
        self.runtimeState = runtimeState
        self.engine = engine ?? WhisperKitEngine(model: settings.whisperModel)
    }

    func prepare(attempts: Int = 3) {
        startLoading(attempts: attempts, showLoadingImmediately: false)
    }

    func reload(using model: String) {
        loadTask?.cancel()
        engine.unload()
        engine = WhisperKitEngine(model: model)
        runtimeState.engineStatus = .loading
        overlay.showModelLoading()
        startLoading(attempts: 1, showLoadingImmediately: true)
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        try await engine.transcribe(audioSamples: audioSamples)
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        engine.unload()
    }

    private func startLoading(attempts: Int, showLoadingImmediately: Bool) {
        loadTask?.cancel()
        let engine = engine
        loadGeneration += 1
        let generation = loadGeneration

        loadTask = Task { @MainActor [weak self, generation] in
            guard let self else { return }
            defer {
                if self.loadGeneration == generation {
                    self.loadTask = nil
                }
            }

            if !showLoadingImmediately {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if !engine.isReady {
                    self.overlay.showModelLoading()
                }
            }

            for attempt in 1...attempts {
                guard !Task.isCancelled else {
                    self.overlay.hideModelLoading()
                    return
                }
                do {
                    try await engine.prepare()
                    guard !Task.isCancelled else {
                        self.overlay.hideModelLoading()
                        return
                    }
                    self.runtimeState.engineStatus = .ready
                    self.overlay.hideModelLoading()
                    return
                } catch is CancellationError {
                    self.overlay.hideModelLoading()
                    return
                } catch {
                    AppLogger.transcription.error(
                        "Engine setup attempt \(attempt)/\(attempts) failed: \(error)"
                    )
                    if attempt < attempts {
                        try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                    }
                }
            }

            self.runtimeState.engineStatus = .failed
            self.overlay.hideModelLoading()
            AppLogger.transcription.error("Engine setup failed after \(attempts) attempts")
        }
    }
}
