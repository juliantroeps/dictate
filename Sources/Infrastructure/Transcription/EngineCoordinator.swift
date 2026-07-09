import Foundation

@MainActor
protocol EngineSettingsManaging: AnyObject {
    var whisperModel: String { get }
}

@MainActor
protocol TranscriptionEngineCoordinating: AnyObject, Sendable {
    var isReady: Bool { get }
    /// Called on the main actor when the engine transitions to ready.
    var onReady: (@MainActor () -> Void)? { get set }
    /// Called on the main actor when all load attempts fail.
    var onLoadFailed: (@MainActor () -> Void)? { get set }
    func prepare(attempts: Int)
    func reload(using model: String)
    /// Swap in a fresh engine instance for the current model, e.g. after a
    /// transcription timeout leaves the previous instance wedged. The old
    /// instance is unloaded in the background; it is never awaited in place
    /// since a wedged actor call would never return.
    func recover()
    func transcribe(audioSamples: [Float]) async throws -> String
    func unload()
}

extension Settings: EngineSettingsManaging {}

@MainActor
final class EngineCoordinator: TranscriptionEngineCoordinating {
    private let settings: any EngineSettingsManaging
    private let overlay: any OverlayControlling
    private let runtimeState: DictationRuntimeState
    private let engineFactory: (String) -> TranscriptionEngine
    private let retryDelay: (Int) -> Duration
    private var engine: TranscriptionEngine
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: Int = 0

    var isReady: Bool { engine.isReady }
    var onReady: (@MainActor () -> Void)?
    var onLoadFailed: (@MainActor () -> Void)?

    init(
        settings: any EngineSettingsManaging = Settings.shared,
        overlay: any OverlayControlling = OverlayController(),
        runtimeState: DictationRuntimeState = DictationRuntimeState(),
        engine: TranscriptionEngine? = nil,
        engineFactory: @escaping (String) -> TranscriptionEngine = { WhisperKitEngine(model: $0) },
        retryDelay: @escaping (Int) -> Duration = { .seconds(Double($0) * 2) }
    ) {
        self.settings = settings
        self.overlay = overlay
        self.runtimeState = runtimeState
        self.engineFactory = engineFactory
        self.retryDelay = retryDelay
        self.engine = engine ?? engineFactory(settings.whisperModel)
    }

    func prepare(attempts: Int = 3) {
        startLoading(attempts: attempts, showLoadingImmediately: false)
    }

    func reload(using model: String) {
        swapEngine(to: model)
    }

    func recover() {
        swapEngine(to: settings.whisperModel)
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        try await engine.transcribe(audioSamples: audioSamples)
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        let old = engine
        Task { await old.unload() }
    }

    /// Swap the current engine for a fresh instance and kick off its load.
    /// The old instance is unloaded off the critical path - it must never be
    /// awaited here, since a wedged actor call (the exact case `recover()`
    /// exists for) would never return.
    private func swapEngine(to model: String) {
        loadTask?.cancel()
        let old = engine
        engine = engineFactory(model)
        runtimeState.engineStatus = .loading
        overlay.showModelLoading()
        startLoading(attempts: 1, showLoadingImmediately: true)
        Task { await old.unload() }
    }

    private func startLoading(attempts: Int, showLoadingImmediately: Bool) {
        // Join an in-flight load rather than cancelling and restarting it.
        // Restarting cancels a healthy launch load whose WhisperKit(config) init
        // does not observe cancellation promptly, allowing two concurrent model
        // builds on the same engine instance.
        if loadTask != nil, !showLoadingImmediately { return }

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

            // Overlay grace timer runs concurrently so it never gates the model load.
            // Start the engine prepare loop immediately; show the overlay only if
            // the load is still in progress after 1s.
            let graceTask: Task<Void, Never>?
            if !showLoadingImmediately {
                graceTask = Task { @MainActor [weak self, generation] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    if !engine.isReady, self.loadGeneration == generation {
                        self.overlay.showModelLoading()
                    }
                }
            } else {
                graceTask = nil
            }
            defer { graceTask?.cancel() }

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
                    self.onReady?()
                    return
                } catch is CancellationError {
                    self.overlay.hideModelLoading()
                    return
                } catch {
                    AppLogger.transcription.error(
                        "Engine setup attempt \(attempt)/\(attempts) failed: \(error)"
                    )
                    if attempt < attempts {
                        try? await Task.sleep(for: self.retryDelay(attempt))
                    }
                }
            }

            self.runtimeState.engineStatus = .failed
            self.overlay.hideModelLoading()
            AppLogger.transcription.error("Engine setup failed after \(attempts) attempts")
            self.onLoadFailed?()
        }
    }
}
