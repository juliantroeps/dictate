import Foundation

@MainActor
protocol EngineSettingsManaging: AnyObject {
    var whisperModel: String { get }
    var engineState: EngineState { get set }
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
    private var engine: TranscriptionEngine
    private var loadTask: Task<Void, Never>?

    var isReady: Bool { engine.isReady }

    init(
        settings: any EngineSettingsManaging = Settings.shared,
        overlay: any OverlayControlling = OverlayController(),
        engine: TranscriptionEngine? = nil
    ) {
        self.settings = settings
        self.overlay = overlay
        self.engine = engine ?? WhisperKitEngine(model: settings.whisperModel)
    }

    func prepare(attempts: Int = 3) {
        startLoading(attempts: attempts, showLoadingImmediately: false)
    }

    func reload(using model: String) {
        loadTask?.cancel()
        engine.unload()
        engine = WhisperKitEngine(model: model)
        settings.engineState = .loading
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

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }

            if !showLoadingImmediately {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if !engine.isReady {
                    self.overlay.showModelLoading()
                }
            }

            for attempt in 1...attempts {
                do {
                    try await engine.prepare()
                    guard !Task.isCancelled else {
                        self.overlay.hideModelLoading()
                        return
                    }
                    self.settings.engineState = .ready
                    self.overlay.hideModelLoading()
                    return
                } catch is CancellationError {
                    self.overlay.hideModelLoading()
                    return
                } catch {
                    print("[dictate] Engine setup attempt \(attempt)/\(attempts) failed: \(error)")
                    if attempt < attempts {
                        try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                    }
                }
            }

            self.settings.engineState = .failed
            self.overlay.hideModelLoading()
            print("[dictate] Engine setup failed after \(attempts) attempts")
        }
    }
}
