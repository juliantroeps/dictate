import Testing
import Foundation

@testable import dictate

struct DictationCoordinatorTests {
    @Test @MainActor
    func shortPressReturnsToIdleWithoutTranscription() {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.4
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        var injectedTexts: [String] = []

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { text in
                injectedTexts.append(text)
                return .injected
            }
        )

        coordinator.handleKeyDown()
        currentTime += 100_000_000
        coordinator.handleKeyUp()

        #expect(overlay.state.phase == .idle)
        #expect(engine.prepareAttempts.isEmpty)
        #expect(engine.transcribeInputs.isEmpty)
        #expect(injectedTexts.isEmpty)
        #expect(audioCapture.stopRecordingCalls == 1)
    }

    @Test @MainActor
    func engineNotReadyShowsLoadingStateAndTriggersPrepare() {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = false

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) }
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        #expect(overlay.state.phase == .error("Model loading..."))
        #expect(engine.prepareAttempts == [1])
        #expect(engine.transcribeInputs.isEmpty)
    }

    @Test @MainActor
    func timeoutHandlingSurfacesTimeoutError() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
        engine.transcribeBehavior = { _ in
            try await Task.sleep(for: .milliseconds(50))
            return "hello world"
        }

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            transcriptionTimeout: .milliseconds(10)
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        let task = coordinator.runtimeState.transcriptionTask
        #expect(task != nil)
        await task?.value

        #expect(overlay.state.phase == .error("Transcription timed out"))
        #expect(engine.transcribeInputs.count == 1)
    }

    @Test @MainActor
    func interruptionCleanupCancelsTranscriptionAndUnmutesAudio() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = true

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
        engine.transcribeBehavior = { _ in
            try await Task.sleep(for: .milliseconds(100))
            return "hello world"
        }
        let muting = MutingRecorder()

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            transcriptionTimeout: .milliseconds(500),
            setMuted: { muted in
                muting.setMuted(muted)
            }
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        let task = coordinator.runtimeState.transcriptionTask
        #expect(task != nil)

        coordinator.handleRecordingInterrupted(samples: [])
        await task?.value

        #expect(muting.values.last == false)
        #expect(coordinator.runtimeState.keyDownTime == nil)
        #expect(overlay.state.phase == .idle)
        #expect(engine.transcribeInputs.count == 1)
    }
}
