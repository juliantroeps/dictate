import AppKit
import CoreAudio
import Foundation
import Testing

@testable import dictate

@Suite(.serialized)
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
    func engineNotReadyBuffersSamplesAndTriggersPrepare() {
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
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        #expect(overlay.state.phase == .modelLoading)
        #expect(engine.prepareAttempts == [1])
        #expect(engine.transcribeInputs.isEmpty)
        #expect(coordinator.runtimeState.pendingSamples != nil)
    }

    @Test @MainActor
    func engineBecomesReadyFlushesBufferedSamples() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = false
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
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        #expect(coordinator.runtimeState.pendingSamples != nil)
        #expect(engine.transcribeInputs.isEmpty)

        // Engine becomes ready - should flush the buffered samples.
        engine.becomeReady()

        await coordinator.runtimeState.transcriptionTask?.value

        #expect(engine.transcribeInputs.count == 1)
        #expect(injectedTexts == ["transcribed text"])
        #expect(coordinator.runtimeState.pendingSamples == nil)
        #expect(overlay.state.phase == .idle)
    }

    @Test @MainActor
    func interruptedWhileNotReadyBuffersAndFlushesOnReady() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = false
        var injectedTexts: [String] = []

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            injectText: { text in
                injectedTexts.append(text)
                return .injected
            }
        )

        let minSamples = Int(settings.minHoldDuration * 16000) + 1
        let samples = [Float](repeating: 0.1, count: minSamples)
        coordinator.handleRecordingInterrupted(samples: samples)

        #expect(coordinator.runtimeState.pendingSamples != nil)
        #expect(engine.prepareAttempts == [1])
        #expect(engine.transcribeInputs.isEmpty)

        engine.becomeReady()

        await coordinator.runtimeState.transcriptionTask?.value

        #expect(engine.transcribeInputs.count == 1)
        #expect(injectedTexts == ["transcribed text"])
        #expect(coordinator.runtimeState.pendingSamples == nil)
        #expect(overlay.state.phase == .idle)
    }

    @Test @MainActor
    func freshKeyDownClearsStalePendingBuffer() {
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
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted }
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        #expect(coordinator.runtimeState.pendingSamples != nil)

        // A new key-down must clear the stale buffer.
        coordinator.handleKeyDown()
        #expect(coordinator.runtimeState.pendingSamples == nil)
    }

    @Test @MainActor
    func lateReadyAfterNewSessionDoesNotDoubleInject() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = false
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

        // First key-up while not ready -> buffers samples.
        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()
        #expect(coordinator.runtimeState.pendingSamples != nil)

        // New session starts (key-down clears stale buffer) then a ready transcription runs.
        coordinator.handleKeyDown()
        #expect(coordinator.runtimeState.pendingSamples == nil)
        engine.isReady = true
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        let newTask = coordinator.runtimeState.transcriptionTask
        await newTask?.value

        // Now becomeReady fires the old onReady callback - the stale flush must not inject again.
        engine.becomeReady()
        await coordinator.runtimeState.transcriptionTask?.value

        // Only one injection from the new ready session.
        #expect(injectedTexts.count == 1)
    }

    @Test @MainActor
    func loadFailureWhileBufferedClearsBufferAndShowsError() {
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
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted }
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        #expect(coordinator.runtimeState.pendingSamples != nil)

        // Simulate load failure.
        engine.failLoad()

        #expect(coordinator.runtimeState.pendingSamples == nil)
        #expect(overlay.state.phase == .error("Transcription failed"))
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
            transcriptionTimeout: .milliseconds(10),
            injectText: { _ in .pasted },
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
        let fakeMute = FakeMuteController()
        // device 1 is unmuted initially
        fakeMute.mutedState[1] = false

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            transcriptionTimeout: .milliseconds(500),
            injectText: { _ in .pasted },
            muteController: fakeMute.makeController()
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        let task = coordinator.runtimeState.transcriptionTask
        #expect(task != nil)

        coordinator.handleRecordingInterrupted(samples: [])
        await task?.value

        // Interruption path should have restored mute to prior (false) state
        #expect(fakeMute.calls.last?.muted == false)
        #expect(fakeMute.calls.last?.device == 1)
        #expect(coordinator.runtimeState.keyDownTime == nil)
        #expect(overlay.state.phase == .idle)
        #expect(engine.transcribeInputs.count == 1)
    }

    // MARK: - Mute lifecycle tests

    @Test @MainActor
    func muteHappyPathRestoresUnmuted() {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = true

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        let fakeMute = FakeMuteController()
        fakeMute.mutedState[1] = false // device 1 starts unmuted

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
            muteController: fakeMute.makeController()
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        // Should have muted on key-down then restored false on key-up
        #expect(fakeMute.calls.count == 2)
        #expect(fakeMute.calls[0] == (muted: true, device: 1))
        #expect(fakeMute.calls[1] == (muted: false, device: 1))
    }

    @Test @MainActor
    func defaultDeviceChangesMidHold_originalDeviceRestored() {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = true

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        let fakeMute = FakeMuteController()
        fakeMute.currentDevice = 1
        fakeMute.settable = [1, 2]
        fakeMute.mutedState[1] = false
        fakeMute.mutedState[2] = false

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
            muteController: fakeMute.makeController()
        )

        coordinator.handleKeyDown()
        // Simulate AirPods disconnect - default device changes mid-hold
        fakeMute.currentDevice = 2
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        // Key-up must restore original device 1, not the new device 2
        #expect(fakeMute.calls.last?.device == 1)
        #expect(fakeMute.calls.last?.muted == false)
    }

    @Test @MainActor
    func settingToggledOffMidHold_stillRestoresMute() {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = true

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        let fakeMute = FakeMuteController()
        fakeMute.mutedState[1] = false

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
            muteController: fakeMute.makeController()
        )

        coordinator.handleKeyDown()
        // Toggle setting off mid-hold
        settings.muteSystemAudio = false
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        // Key-up should still restore mute via activeMute, regardless of current setting
        #expect(fakeMute.calls.last?.muted == false)
        #expect(fakeMute.calls.last?.device == 1)
    }

    @Test @MainActor
    func priorMutePreserved_noCoordinator() {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = true

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        let fakeMute = FakeMuteController()
        // device 1 is already muted by the user
        fakeMute.mutedState[1] = true

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
            muteController: fakeMute.makeController()
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        // Should not have called setMuted at all - user's mute is preserved
        #expect(fakeMute.calls.isEmpty)
        #expect(coordinator.runtimeState.activeMute == nil)
    }

    @Test @MainActor
    func permissionDeniedKeyUp_doesNotUnmute() {
        let settings = FakeDictationSettings()
        settings.muteSystemAudio = true

        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        let fakeMute = FakeMuteController()
        fakeMute.mutedState[1] = false

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            injectText: { _ in .pasted },
            muteController: fakeMute.makeController()
        )

        // No handleKeyDown (simulates permission-denied early return), call handleKeyUp directly
        coordinator.handleKeyUp()

        #expect(fakeMute.calls.isEmpty)
    }

    // MARK: - Discard mode tests

    @Test @MainActor
    func discardModeWithNoTarget_dropsWithoutInjecting() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false
        settings.noFocusBehavior = .discard

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
        var injectedTexts: [String] = []

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { text in
                injectedTexts.append(text)
                return .copiedToClipboard
            },
            hasInjectableTarget: { false }
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        await coordinator.runtimeState.transcriptionTask?.value

        #expect(injectedTexts.isEmpty)
        #expect(overlay.state.phase == .idle)
        #expect(engine.transcribeInputs.count == 1)
    }

    @Test @MainActor
    func discardModeWithTarget_injectsNormally() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false
        settings.noFocusBehavior = .discard

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
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
            },
            hasInjectableTarget: { true }
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        await coordinator.runtimeState.transcriptionTask?.value

        #expect(injectedTexts == ["transcribed text"])
        #expect(overlay.state.phase == .idle)
    }

    @Test @MainActor
    func clipboardModeAlwaysInjects() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false
        settings.noFocusBehavior = .clipboard

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
        var injectedTexts: [String] = []

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { text in
                injectedTexts.append(text)
                return .copiedToClipboard
            },
            hasInjectableTarget: { false }
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        await coordinator.runtimeState.transcriptionTask?.value

        #expect(injectedTexts.count == 1)
        #expect(overlay.state.phase == .idle)
    }

    @Test @MainActor
    func discardModeNoTargetInterruptedPath_dropsWithoutInjecting() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false
        settings.noFocusBehavior = .discard

        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
        var injectedTexts: [String] = []

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            injectText: { text in
                injectedTexts.append(text)
                return .copiedToClipboard
            },
            hasInjectableTarget: { false }
        )

        let minSamples = Int(settings.minHoldDuration * 16000) + 1
        let samples = [Float](repeating: 0.1, count: minSamples)
        coordinator.handleRecordingInterrupted(samples: samples)

        await coordinator.runtimeState.transcriptionTask?.value

        #expect(injectedTexts.isEmpty)
        #expect(overlay.state.phase == .idle)
        #expect(engine.transcribeInputs.count == 1)
    }

    @Test @MainActor
    func discardModeWithNoTarget_dropsBeforeInjecting_pastedVariant() async {
        // Proves the guard keys on hasInjectableTarget(), not on the injection result.
        // Even if injectText would have returned .pasted (e.g. clipboard-paste path),
        // discard mode must drop the dictation without ever calling injectText.
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false
        settings.noFocusBehavior = .discard

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
        var injectedTexts: [String] = []

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { text in
                injectedTexts.append(text)
                return .pasted
            },
            hasInjectableTarget: { false }
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        await coordinator.runtimeState.transcriptionTask?.value

        #expect(injectedTexts.isEmpty)
        #expect(overlay.state.phase == .idle)
        #expect(engine.transcribeInputs.count == 1)
    }

    @Test @MainActor
    func discardModeWithNoTarget_doesNotTouchPasteboard() async {
        // Sentinel: seeds the real NSPasteboard and asserts it is untouched after
        // a discard + no-target flow. The fake injectText closure is never called,
        // so the only way the pasteboard could change is if the coordinator (or
        // anything it calls) writes to it directly - which it must not.
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false
        settings.noFocusBehavior = .discard

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
        var injectedTexts: [String] = []

        // Use a private named pasteboard, never the user's real .general clipboard.
        let pb = NSPasteboard(name: NSPasteboard.Name("dictate.tests.discard"))
        pb.clearContents()
        pb.setString("USER-PRIOR-CLIPBOARD", forType: .string)

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { text in
                injectedTexts.append(text)
                return .copiedToClipboard
            },
            hasInjectableTarget: { false }
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        await coordinator.runtimeState.transcriptionTask?.value

        #expect(pb.string(forType: .string) == "USER-PRIOR-CLIPBOARD")
        #expect(injectedTexts.isEmpty)
    }

    @Test @MainActor
    func discardModeInterruptedPath_doesNotTouchPasteboard() async {
        // Sentinel for the interrupted-dictation entry point cited in the issue.
        // After an interrupted recording in discard+no-target mode, the pasteboard
        // must remain exactly as the user left it.
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false
        settings.noFocusBehavior = .discard

        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
        var injectedTexts: [String] = []

        // Use a private named pasteboard, never the user's real .general clipboard.
        let pb = NSPasteboard(name: NSPasteboard.Name("dictate.tests.discard"))
        pb.clearContents()
        pb.setString("USER-PRIOR-CLIPBOARD", forType: .string)

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            injectText: { text in
                injectedTexts.append(text)
                return .copiedToClipboard
            },
            hasInjectableTarget: { false }
        )

        let minSamples = Int(settings.minHoldDuration * 16000) + 1
        let samples = [Float](repeating: 0.1, count: minSamples)
        coordinator.handleRecordingInterrupted(samples: samples)

        await coordinator.runtimeState.transcriptionTask?.value

        #expect(pb.string(forType: .string) == "USER-PRIOR-CLIPBOARD")
        #expect(injectedTexts.isEmpty)
    }

    // MARK: - Device-change re-arm tests

    @Test @MainActor
    func deviceChangeWhileHeld_restartsCaptureOnStableConfig() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000

        // Wait for initial startRecording task to complete
        let initialStartTask = coordinator.runtimeState.recordingStartTask
        await initialStartTask?.value
        #expect(audioCapture.startRecordingCalls == 1)

        let minSamples = Int(settings.minHoldDuration * 16000) + 1
        let samples = [Float](repeating: 0.1, count: minSamples)
        coordinator.handleRecordingInterrupted(samples: samples)

        // keyDownTime cleared, keyHeld still true
        #expect(coordinator.runtimeState.keyDownTime == nil)
        #expect(coordinator.runtimeState.keyHeld == true)

        // Stable config event triggers re-arm
        coordinator.handleAudioCaptureEvent(.inputConfigurationChanged(stable: true))

        // keyDownTime restored, phase set to recording
        #expect(coordinator.runtimeState.keyDownTime != nil)
        #expect(coordinator.runtimeState.keyHeld == true)

        let restartTask = coordinator.runtimeState.recordingStartTask
        await restartTask?.value

        #expect(audioCapture.startRecordingCalls == 2)
        #expect(overlay.state.phase == .recording)
    }

    @Test @MainActor
    func deviceChangeAfterRelease_doesNotRestartCapture() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        // keyHeld cleared on key-up
        #expect(coordinator.runtimeState.keyHeld == false)

        await coordinator.runtimeState.transcriptionTask?.value

        let callsBefore = audioCapture.startRecordingCalls
        coordinator.handleAudioCaptureEvent(.inputConfigurationChanged(stable: true))

        // No restart - key is not held
        #expect(audioCapture.startRecordingCalls == callsBefore)
        #expect(overlay.state.phase == .idle)
    }

    @Test @MainActor
    func unstableConfigWhileHeld_doesNotRestart() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000

        let initialTask = coordinator.runtimeState.recordingStartTask
        await initialTask?.value
        #expect(audioCapture.startRecordingCalls == 1)

        let minSamples = Int(settings.minHoldDuration * 16000) + 1
        let samples = [Float](repeating: 0.1, count: minSamples)
        coordinator.handleRecordingInterrupted(samples: samples)

        // Unstable event - should not restart
        coordinator.handleAudioCaptureEvent(.inputConfigurationChanged(stable: false))

        #expect(audioCapture.startRecordingCalls == 1)
    }

    @Test @MainActor
    func releaseAfterInterruptionWithoutRestart_clearsKeyHeldAndIdles() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
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
        currentTime += 100_000_000 // < minHoldDuration (0.1s = 100ms, exactly at boundary - use less)

        // Short sample count - below minSamples threshold
        coordinator.handleRecordingInterrupted(samples: [0.1])
        // keyHeld still true at this point
        #expect(coordinator.runtimeState.keyHeld == true)

        // User releases key
        coordinator.handleKeyUp()
        #expect(coordinator.runtimeState.keyHeld == false)
        #expect(overlay.state.phase == .idle)
        // No extra transcription from the short interrupted segment
        #expect(injectedTexts.isEmpty)
    }

    @Test @MainActor
    func restartGuardsAgainstDoubleArm() async {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        // Give startRecording a delay so the task is still in flight on second event
        audioCapture.startRecordingDelay = .milliseconds(50)
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000

        let minSamples = Int(settings.minHoldDuration * 16000) + 1
        let samples = [Float](repeating: 0.1, count: minSamples)
        coordinator.handleRecordingInterrupted(samples: samples)

        // First stable event - starts re-arm task
        coordinator.handleAudioCaptureEvent(.inputConfigurationChanged(stable: true))
        let restartTask = coordinator.runtimeState.recordingStartTask
        #expect(restartTask != nil)

        // Second stable event - should be ignored because task is still in flight
        coordinator.handleAudioCaptureEvent(.inputConfigurationChanged(stable: true))

        await restartTask?.value

        // Only 2 calls total: initial key-down + one restart (not 3)
        #expect(audioCapture.startRecordingCalls == 2)
    }

    // MARK: - Failure-path recovery

    @Test @MainActor
    func transcriptionFailure_showsErrorThenRecoverOnNextPress() async {
        // Verifies the single source of truth (overlay.state.phase) recovers cleanly
        // after a transcription error - the old runtimeState.phase would have stuck
        // at .processing, leaving the state machine permanently desynced.
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        struct FakeError: Error {}
        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true
        engine.transcribeBehavior = { _ in throw FakeError() }

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
        )

        // First press -> release -> transcription fails.
        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        let task = coordinator.runtimeState.transcriptionTask
        #expect(task != nil)
        await task?.value

        #expect(overlay.state.phase == .error("Transcription failed"))

        // Second press must move state to .recording, not stay stuck at .error.
        coordinator.handleKeyDown()
        #expect(overlay.state.phase == .recording)
    }

    // MARK: - Hot-mic regression test

    @Test @MainActor
    func keyUpDuringSlowStart_micStaysCold() async {
        // Regression: if key-up cancels the recordingStartTask while startRecording()
        // is suspended (e.g. in a retry backoff sleep), stopRecording() no-ops because
        // isRecording is still false. The start task must honour cancellation and NOT
        // set isRecordingAfterStart = true after the key-up cancel lands.
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = false

        let audioCapture = FakeAudioCaptureManager()
        // Slow enough that handleKeyUp's cancel lands while the task is suspended.
        audioCapture.startRecordingDelay = .milliseconds(50)
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        engine.isReady = true

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            injectText: { _ in .pasted },
        )

        coordinator.handleKeyDown()
        // Capture the task handle before handleKeyUp nils it.
        let startTask = coordinator.runtimeState.recordingStartTask
        #expect(startTask != nil)

        // Immediately release - cancels recordingStartTask and calls stopRecording (no-op).
        coordinator.handleKeyUp()

        // Drain the start task so any resumed work completes before we assert.
        await startTask?.value

        // The mic must be cold: isRecordingAfterStart must remain false.
        #expect(audioCapture.isRecordingAfterStart == false)
    }

    @Test @MainActor
    func nonSettableDevice_noMuteAttempt() {
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.1
        settings.muteSystemAudio = true

        var currentTime: UInt64 = 1_000_000_000
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        let fakeMute = FakeMuteController()
        // device 1 is NOT settable (e.g. USB DAC with no master mute)
        fakeMute.settable = []
        fakeMute.mutedState[1] = false

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
            muteController: fakeMute.makeController()
        )

        coordinator.handleKeyDown()
        currentTime += 500_000_000
        coordinator.handleKeyUp()

        // No mute calls and no activeMute stored
        #expect(fakeMute.calls.isEmpty)
        #expect(coordinator.runtimeState.activeMute == nil)
    }
}
