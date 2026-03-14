import Foundation

@MainActor
final class EngineManager {
    private(set) var engine: TranscriptionEngine
    private var loadTask: Task<Void, Never>?
    private let settings = Settings.shared
    var onLoadingStateChanged: ((Bool) -> Void)?

    init() {
        self.engine = WhisperKitEngine(model: Settings.shared.whisperModel)
    }

    var isReady: Bool { engine.isReady }

    func prepare(attempts: Int = 3) {
        loadTask = Task {
            // Suppress loading indicator if model loads quickly (cached)
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            if !engine.isReady {
                onLoadingStateChanged?(true)
            }

            for attempt in 1...attempts {
                do {
                    try await engine.prepare()
                    guard !Task.isCancelled else {
                        onLoadingStateChanged?(false)
                        return
                    }
                    settings.engineState = .ready
                    onLoadingStateChanged?(false)
                    return
                } catch is CancellationError {
                    onLoadingStateChanged?(false)
                    return
                } catch {
                    print("[dictate] Engine setup attempt \(attempt)/\(attempts) failed: \(error)")
                    if attempt < attempts {
                        try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                    }
                }
            }
            settings.engineState = .failed
            onLoadingStateChanged?(false)
            print("[dictate] Engine setup failed after \(attempts) attempts")
        }
    }

    func reload() {
        loadTask?.cancel()
        engine.unload()
        settings.engineState = .loading
        engine = WhisperKitEngine(model: settings.whisperModel)
        onLoadingStateChanged?(true)
        loadTask = Task {
            do {
                try await engine.prepare()
                guard !Task.isCancelled else {
                    onLoadingStateChanged?(false)
                    return
                }
                settings.engineState = .ready
                onLoadingStateChanged?(false)
            } catch is CancellationError {
                onLoadingStateChanged?(false)
            } catch {
                settings.engineState = .failed
                onLoadingStateChanged?(false)
                print("[dictate] Engine reload failed: \(error)")
            }
        }
    }

    func observeModelChanges() {
        withObservationTracking {
            _ = settings.whisperModel
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reload()
                self?.observeModelChanges()
            }
        }
    }
}
