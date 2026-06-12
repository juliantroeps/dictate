import Foundation
import Testing

@testable import dictate

/// Tests for OverlayController generation-token race guards.
/// Uses injectable seams (scheduleAfter, onOrderOut) to control time deterministically.
@Suite(.serialized)
@MainActor
struct OverlayControllerTests {

    // MARK: - Toast race: consecutive same-kind toasts

    @Test
    func consecutiveSameKindToasts_firstTimerDoesNotHideSecond() {
        var scheduledWork: [(TimeInterval, @MainActor () -> Void)] = []

        let overlay = OverlayController(
            scheduleAfter: { delay, work in scheduledWork.append((delay, work)) },
            onOrderOut: nil
        )

        // First error toast - schedules work at index 0.
        overlay.showError("A", duration: 2.0)
        #expect(scheduledWork.count == 1)

        // Second error toast - schedules work at index 1; generation has bumped.
        overlay.showError("B", duration: 2.0)
        #expect(scheduledWork.count == 2)

        // Fire the first toast's scheduled closure (stale generation).
        scheduledWork[0].1()

        // Phase must still be .error("B") - the stale timer must not clobber it.
        #expect(overlay.state.phase == .error("B"))
    }

    // MARK: - Toast race: cross-kind invalidation

    @Test
    func crossKindToast_staleErrorTimerDoesNotHideInfo() {
        var scheduledWork: [@MainActor () -> Void] = []

        let overlay = OverlayController(
            scheduleAfter: { _, work in scheduledWork.append(work) },
            onOrderOut: nil
        )

        overlay.showError("A", duration: 2.0)
        overlay.showInfo("B", duration: 2.0)

        // Fire the error timer (stale).
        scheduledWork[0]()

        #expect(overlay.state.phase == .info("B"))
    }

    // MARK: - Fade race: stale hide() fade does not order out re-shown overlay

    @Test
    func rapidHideShow_staleFadeDoesNotOrderOut() {
        var scheduledWork: [(TimeInterval, @MainActor () -> Void)] = []
        var orderOutCount = 0

        let overlay = OverlayController(
            scheduleAfter: { delay, work in scheduledWork.append((delay, work)) },
            onOrderOut: { orderOutCount += 1 }
        )

        // show() -> hide() (schedules fade-orderOut capturing gen=2) -> show() again (gen=3).
        overlay.show()   // gen 1
        overlay.hide()   // gen 2, appends fade closure at index 0
        overlay.show()   // gen 3

        #expect(scheduledWork.count == 1)

        // Fire the stale gen-2 fade closure - must NOT order out the re-shown overlay.
        scheduledWork[0].1()

        #expect(orderOutCount == 0)
    }

    @Test
    func currentGenerationFade_doesOrderOut() {
        var scheduledWork: [(TimeInterval, @MainActor () -> Void)] = []
        var orderOutCount = 0

        let overlay = OverlayController(
            scheduleAfter: { delay, work in scheduledWork.append((delay, work)) },
            onOrderOut: { orderOutCount += 1 }
        )

        // show() then hide() with no intervening show() - fade should order out.
        overlay.show()  // gen 1
        overlay.hide()  // gen 2, appends fade closure at index 0

        #expect(scheduledWork.count == 1)

        // Fire the current-generation fade closure - must order out.
        scheduledWork[0].1()

        #expect(orderOutCount == 1)
    }

    // MARK: - Latest toast's own timer still hides

    @Test
    func ownTimer_stillHidesWhenCurrentGeneration() {
        var scheduledWork: [@MainActor () -> Void] = []
        var orderOutCount = 0

        let overlay = OverlayController(
            scheduleAfter: { _, work in scheduledWork.append(work) },
            onOrderOut: { orderOutCount += 1 }
        )

        overlay.showInfo("A", duration: 2.0)
        let phaseAfterShow = overlay.state.phase

        // The single scheduled closure is for the current generation.
        #expect(scheduledWork.count == 1)
        #expect(phaseAfterShow == .info("A"))

        // Fire the current-generation timer - it should hide.
        scheduledWork[0]()

        // Phase must have returned to idle (hide() was called by the timer).
        // Since FakeOverlayController.hide() is not used here, the real hide()
        // does not synchronously set phase - we check the timer ran correctly
        // by asserting it set phase to .idle before calling hide().
        #expect(overlay.state.phase == .idle)
    }

    // MARK: - Short-hold + immediate re-press keeps overlay shown

    @Test
    func shortHoldThenRepress_keepsPhasRecording() {
        let audioCapture = FakeAudioCaptureManager()
        let overlay = FakeOverlayController()
        let engine = FakeTranscriptionEngineCoordinator()
        let settings = FakeDictationSettings()
        settings.minHoldDuration = 0.4
        settings.muteSystemAudio = false

        var currentTime: UInt64 = 1_000_000_000

        let coordinator = DictationCoordinator(
            audioCapture: audioCapture,
            overlay: overlay,
            engineCoordinator: engine,
            settings: settings,
            now: { DispatchTime(uptimeNanoseconds: currentTime) },
            injectText: { _ in .pasted },
        )

        // First press.
        coordinator.handleKeyDown()
        #expect(overlay.showCount == 1)

        // Short release (below minHoldDuration).
        currentTime += 100_000_000 // 0.1s < 0.4s
        coordinator.handleKeyUp()
        #expect(overlay.hideCount == 1)

        // Immediate re-press.
        coordinator.handleKeyDown()
        #expect(overlay.showCount == 2)
        #expect(overlay.state.phase == .recording)
    }
}
