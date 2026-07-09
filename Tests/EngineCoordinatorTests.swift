import Foundation
import Testing

@testable import dictate

@Suite(.serialized)
struct EngineCoordinatorTests {
    @Test @MainActor
    func reloadDuringInFlightLaunchDoesNotStickAtLoading() async {
        let settings = FakeEngineSettings(whisperModel: "launch-model")
        let overlay = FakeOverlayController()
        let runtimeState = DictationRuntimeState()

        // Never resolves within the test's lifetime on its own - only cancellation
        // (triggered by reload) ends it.
        let launchEngine = FakeTranscriptionEngine(model: "launch-model")
        launchEngine.prepareDelay = .seconds(5)
        let reloadEngine = FakeTranscriptionEngine(model: "reload-model")

        var createdModels: [String] = []
        let coordinator = EngineCoordinator(
            settings: settings,
            overlay: overlay,
            runtimeState: runtimeState,
            engine: launchEngine,
            engineFactory: { model in
                createdModels.append(model)
                return reloadEngine
            },
            retryDelay: { _ in .milliseconds(1) }
        )

        let completion = LoadCompletion()
        coordinator.onReady = { completion.fire() }
        coordinator.onLoadFailed = { completion.fire() }

        coordinator.prepare(attempts: 3)
        // Launch prepare is now in flight (5s delay) - loadTask != nil.
        coordinator.reload(using: "reload-model")

        await completion.wait()

        #expect(createdModels == ["reload-model"])
        #expect(reloadEngine.prepareCallCount == 1)
        #expect(runtimeState.engineStatus == .ready)
        #expect(overlay.state.phase == .idle)
    }

    @Test @MainActor
    func threeFailedAttemptsMarksFailedAndFiresOnLoadFailedOnce() async {
        let settings = FakeEngineSettings(whisperModel: "always-fails")
        let overlay = FakeOverlayController()
        let runtimeState = DictationRuntimeState()

        struct FakeError: Error {}
        let engine = FakeTranscriptionEngine(model: "always-fails")
        engine.prepareBehavior = { throw FakeError() }

        let coordinator = EngineCoordinator(
            settings: settings,
            overlay: overlay,
            runtimeState: runtimeState,
            engine: engine,
            engineFactory: { FakeTranscriptionEngine(model: $0) },
            retryDelay: { _ in .milliseconds(1) }
        )

        var loadFailedCount = 0
        let completion = LoadCompletion()
        coordinator.onLoadFailed = {
            loadFailedCount += 1
            completion.fire()
        }
        coordinator.onReady = { completion.fire() }

        coordinator.prepare(attempts: 3)
        await completion.wait()

        #expect(loadFailedCount == 1)
        #expect(runtimeState.engineStatus == .failed)
        #expect(engine.prepareCallCount == 3)
    }

    @Test @MainActor
    func reloadWhileLoadInFlightIsNotSwallowedByJoinGuard() async {
        let settings = FakeEngineSettings(whisperModel: "launch-model")
        let overlay = FakeOverlayController()
        let runtimeState = DictationRuntimeState()

        let launchEngine = FakeTranscriptionEngine(model: "launch-model")
        launchEngine.prepareDelay = .seconds(5)
        let reloadEngine = FakeTranscriptionEngine(model: "reload-model")

        var createdModels: [String] = []
        let coordinator = EngineCoordinator(
            settings: settings,
            overlay: overlay,
            runtimeState: runtimeState,
            engine: launchEngine,
            engineFactory: { model in
                createdModels.append(model)
                return reloadEngine
            },
            retryDelay: { _ in .milliseconds(1) }
        )

        coordinator.prepare(attempts: 1)
        // Launch load is in flight (5s delay) - the join guard at
        // `if loadTask != nil, !showLoadingImmediately { return }` would
        // silently drop this reload if it weren't bypassed for reload/recover.
        let completion = LoadCompletion()
        coordinator.onReady = { completion.fire() }
        coordinator.onLoadFailed = { completion.fire() }

        coordinator.reload(using: "reload-model")

        // engineFactory is invoked synchronously inside reload - not swallowed.
        #expect(createdModels == ["reload-model"])

        await completion.wait()

        #expect(reloadEngine.prepareCallCount == 1)
        #expect(runtimeState.engineStatus == .ready)
    }

    @Test @MainActor
    func recoverSwapsToFreshInstanceUsingCurrentSettingsModel() async {
        let settings = FakeEngineSettings(whisperModel: "current-model")
        let overlay = FakeOverlayController()
        let runtimeState = DictationRuntimeState()

        // Simulate an engine that was ready before it wedged on some later call.
        let wedgedEngine = FakeTranscriptionEngine(model: "current-model")
        try? await wedgedEngine.prepare()
        #expect(wedgedEngine.isReady == true)

        var createdModels: [String] = []
        let freshEngine = FakeTranscriptionEngine(model: "current-model")
        let coordinator = EngineCoordinator(
            settings: settings,
            overlay: overlay,
            runtimeState: runtimeState,
            engine: wedgedEngine,
            engineFactory: { model in
                createdModels.append(model)
                return freshEngine
            },
            retryDelay: { _ in .milliseconds(1) }
        )

        #expect(coordinator.isReady == true)

        let completion = LoadCompletion()
        coordinator.onReady = { completion.fire() }
        coordinator.onLoadFailed = { completion.fire() }

        coordinator.recover()

        // isReady flips false immediately - the fresh engine hasn't prepared yet,
        // so the next key-up buffers instead of racing the wedged instance.
        #expect(coordinator.isReady == false)
        #expect(createdModels == ["current-model"])

        await completion.wait()

        #expect(coordinator.isReady == true)
        #expect(runtimeState.engineStatus == .ready)
    }
}
