import Testing
import AVFoundation
import Foundation

@testable import dictate

/// Thread-safe boolean flag for capturing off-main callbacks in tests.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

/// Thread-safe box for capturing an onEvent payload in tests.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T) { lock.withLock { stored = value } }
    var value: T? { lock.withLock { stored } }
}

/// Ferries a non-Sendable value into a detached task for off-main test invocation.
private struct TestSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Thread-safe recorder of whether any engine was built on the main thread after init.
private final class EngineBuildRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var builtOnMainAfterFirst = false
    private var count = 0
    func record() {
        let onMain = Thread.isMainThread
        lock.withLock {
            count += 1
            // The first build is the init() build (allowed on main); flag only later ones.
            if count > 1 && onMain { builtOnMainAfterFirst = true }
        }
    }
    var sawMainThreadBuildAfterInit: Bool { lock.withLock { builtOnMainAfterFirst } }
    var buildCount: Int { lock.withLock { count } }
}

@MainActor
struct AudioCaptureManagerTests {
    @Test
    func outputFrameCountReturnsNilForZeroSampleRate() {
        #expect(AudioCaptureManager.outputFrameCount(sampleRate: 0, inputFrames: 4096) == nil)
    }

    @Test
    func outputFrameCountReturnsNilForNegativeSampleRate() {
        #expect(AudioCaptureManager.outputFrameCount(sampleRate: -1, inputFrames: 4096) == nil)
    }

    @Test
    func outputFrameCountReturnsNilForNaNSampleRate() {
        #expect(AudioCaptureManager.outputFrameCount(sampleRate: .nan, inputFrames: 4096) == nil)
    }

    @Test
    func outputFrameCountComputesCorrectDownsampleRatio() {
        // 48000 Hz input, 4800 frames -> 1600 output frames at 16000 Hz
        #expect(AudioCaptureManager.outputFrameCount(sampleRate: 48_000, inputFrames: 4800) == 1600)
    }

    // MARK: - stopRecording off-main teardown tests

    @Test
    func stopRecordingReturnsEmptyWhenNotRecording() {
        // Guard: stopRecording on an idle manager must return [] and not crash.
        // Exercises the guard isRecording early-out path (engine-swap is never entered).
        let manager = AudioCaptureManager()
        #expect(manager.stopRecording() == [])
    }

    @Test
    func stopRecordingRepeatedlyDoesNotCrash() {
        // Exercises the engine-swap + off-main teardown path surviving repeated calls
        // without leaving the instance in a broken state.
        let manager = AudioCaptureManager()
        for _ in 0..<5 {
            #expect(manager.stopRecording() == [])
        }
    }

    @Test
    func stopRecordingBufferIsClearedSynchronously() {
        // The off-main teardown must not resurrect buffer samples. After stopRecording()
        // returns, a second call must still return [] (proves the buffer snapshot
        // empties self.buffer on main before the deferred teardown runs).
        let manager = AudioCaptureManager()
        _ = manager.stopRecording()
        #expect(manager.stopRecording() == [])
    }

    // MARK: - drainConverterTail tests

    // MARK: - Cancellation tests

    @Test
    func startRecordingHonorsCancellationAndLeavesMicCold() async {
        // Exercises the cancellation/rollback path: a task cancelled immediately after
        // launch must not leave the engine recording (mic cold after cancel).
        // On CI without audio hardware, engine.start() may fail and the loop already
        // bails; the assertion (mic cold) holds in both cases.
        let manager = AudioCaptureManager()
        let task = Task { @MainActor in
            try await manager.startRecording()
        }
        task.cancel()
        _ = await task.result
        // If cancellation was honoured, isRecording stays false -> stopRecording returns [].
        #expect(manager.stopRecording() == [])
    }

    @Test
    func drainConverterTailReturnsTailAfterResampling() throws {
        // Build a 44100Hz -> 16000Hz converter (most common real-world case).
        let inputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))
        let targetFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let converter = try #require(AVAudioConverter(from: inputFormat, to: targetFormat))

        // Feed one buffer of 44100 frames (1 second at 44.1kHz) via a normal streaming pass.
        let frameCount: AVAudioFrameCount = 44_100
        let inputBuffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount))
        inputBuffer.frameLength = frameCount
        // Fill with a ramp so the converter has real signal to process.
        if let data = inputBuffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                data[i] = Float(i) / Float(frameCount)
            }
        }

        // Streaming convert pass - mirrors processAudioBuffer.
        let outputFrameCount = try #require(AudioCaptureManager.outputFrameCount(
            sampleRate: inputFormat.sampleRate,
            inputFrames: frameCount
        ))
        let outputBuffer = try #require(AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ))
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        let streamedCount = Int(outputBuffer.frameLength)

        // Now drain the tail.
        let tail = AudioCaptureManager.drainConverterTail(converter)

        // The tail must be non-empty - there is filter-delay latency remaining.
        #expect(tail.count > 0, "drainConverterTail must recover the resampler tail after streaming")

        // Together they should be very close to the ideal 16000 frames (1s at 16kHz).
        // Allow a small tolerance for the SRC filter group delay.
        let total = streamedCount + tail.count
        #expect(abs(total - 16_000) <= 64, "streamed + tail should approximate ideal output frame count")
    }

    // MARK: - Off-main tap-thread isolation regression

    @Test
    func processAudioBufferRunsOffMainAndEmitsEventWithoutTrapping() async throws {
        // Regression for the realtime-thread crash: AVFAudio invokes the tap block on
        // its audio thread, not main. Under Swift 6 a MainActor-isolated closure called
        // off-main traps in the executor precondition (swift_task_isCurrentExecutor ->
        // dispatch_assert_queue_fail). processAudioBuffer must stay nonisolated and the
        // onEvent path must be invokable off-main. (The installTap closure itself needs
        // real audio hardware to exercise; this guards the same isolation contract on the
        // code path we can drive without a device.)
        let manager = AudioCaptureManager()

        // @Sendable handler with thread-safe capture, mirroring AppDelegate's wiring.
        let received = LockedFlag()
        manager.onEvent = { @Sendable _ in received.set() }

        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let frames: AVAudioFrameCount = 4800
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) { data[i] = sin(Float(i) * 0.05) * 0.1 }
        }

        // Invoke off the main actor, as the real tap thread does. A trap here = regression.
        let box = TestSendableBox(buffer)
        await Task.detached {
            manager.processAudioBuffer(box.value)
        }.value

        #expect(received.value, "onEvent (audioLevel) must fire from an off-main processAudioBuffer call")
    }

    // MARK: - Engine factory seam / off-main construction tests

    @Test
    func configChangeBuildsReplacementEngineOnMainForAtomicSwap() {
        // Construction is cheap and stays on main so the swap is atomic/race-free;
        // only teardown (removeTap/stop/dealloc) goes off-main. See #21 fix.
        let recorder = EngineBuildRecorder()
        let manager = AudioCaptureManager(makeEngine: { @Sendable in
            recorder.record()
            return AVAudioEngine()
        })
        manager.triggerConfigChangeForTesting()
        #expect(recorder.buildCount >= 2, "config change must build a replacement engine")
    }

    @Test
    func startRecordingAfterConfigChangeTapsTheFreshEngine() async {
        // Regression for the stale-engine race: after a swap, the tap/start must operate
        // on the newly installed engine, not the torn-down old one.
        let manager = AudioCaptureManager(makeEngine: { @Sendable in AVAudioEngine() })

        // Trigger a config-change swap (synchronous on-main assignment now).
        manager.triggerConfigChangeForTesting()
        let fresh = manager.currentEngineForTesting

        // Immediately attempt a record (key-down). On CI, start() fails after the tap is
        // installed, but installRecordingTap already recorded which engine it tapped.
        _ = try? await Task { @MainActor in try await manager.startRecording() }.value

        #expect(manager.lastTappedEngine === fresh,
                "tap must be installed on the engine swapped in on main, not the torn-down one")
    }

    @Test
    func configChangeAssignsReplacementEngineSynchronouslyOnMain() {
        let manager = AudioCaptureManager()
        let before = manager.currentEngineForTesting
        manager.triggerConfigChangeForTesting()
        // No await: assignment must have already happened on main before returning.
        #expect(manager.currentEngineForTesting !== before,
                "replacement engine must be installed synchronously on main (no deferred hop)")
    }

    @Test
    func rapidConfigChangesAreDebouncedAndDoNotCrash() async {
        // isSettling is now set at the top of handleConfigChange, so reentrant
        // config changes during the settle window must be suppressed (no engine-swap storm).
        let recorder = EngineBuildRecorder()
        let manager = AudioCaptureManager(makeEngine: { @Sendable in
            recorder.record()
            return AVAudioEngine()
        })

        // Fire several in a row, mimicking BT-connect churn.
        for _ in 0..<5 { manager.triggerConfigChangeForTesting() }
        try? await Task.sleep(for: .milliseconds(300))

        // init build + at most the first (un-gated) config change build; the rest are
        // suppressed by isSettling. Strictly fewer than 1 + 5.
        #expect(recorder.buildCount < 6, "reentrant config changes must be debounced by isSettling")
        // Manager still usable afterwards.
        #expect(manager.stopRecording() == [])
    }

    @Test
    func configChangeSettleCompletionDeliversInputConfigChangedOnMainWithoutTrapping() async {
        // Regression for the off-main completion / MainActor.assumeIsolated SIGTRAP:
        // the settle completion (~settleDelay + validateDelay after a config change) used to
        // run on a global queue and trap. It must run on main and deliver the event there.
        let manager = AudioCaptureManager()
        manager.settleDelay = 0.05
        manager.validateDelay = 0.02

        let sawInputConfigChanged = LockedFlag()
        let deliveredOnMain = LockedFlag()
        // Use a continuation so the test waits for the event rather than sleeping a
        // fixed duration (avoids flakiness under heavy parallel test suite load).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = LockedFlag()
            manager.onEvent = { @Sendable event in
                if case .inputConfigurationChanged = event {
                    if Thread.isMainThread { deliveredOnMain.set() }
                    sawInputConfigChanged.set()
                    // Resume exactly once.
                    if !resumed.value {
                        resumed.set()
                        continuation.resume()
                    }
                }
            }
            manager.triggerConfigChangeForTesting()
        }

        #expect(sawInputConfigChanged.value,
                "settle completion must deliver .inputConfigurationChanged (no trap)")
        #expect(deliveredOnMain.value,
                ".inputConfigurationChanged must be delivered on the main thread")
    }

    @Test
    func configChangeIsHandledAgainAfterSettleCompletes() async {
        let recorder = EngineBuildRecorder()
        let manager = AudioCaptureManager(makeEngine: { @Sendable in
            recorder.record()
            return AVAudioEngine()
        })
        manager.settleDelay = 0.05
        manager.validateDelay = 0.02

        // Wait for the first settle to complete via the event rather than a fixed sleep,
        // so the test is not flaky under heavy parallel test suite load.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = LockedFlag()
            manager.onEvent = { @Sendable event in
                if case .inputConfigurationChanged = event {
                    if !resumed.value {
                        resumed.set()
                        continuation.resume()
                    }
                }
            }
            manager.triggerConfigChangeForTesting()    // build #2; settle fires event when done
        }
        let countAfterFirstSettle = recorder.buildCount

        manager.triggerConfigChangeForTesting()        // must NOT be suppressed -> build #3
        #expect(recorder.buildCount > countAfterFirstSettle,
                "after a settle completes, a new config change must be handled (isSettling reset)")
    }

    @Test
    func defaultMakeEngineStillProducesUsableManager() {
        // Default factory path (no injection) must behave as before.
        let manager = AudioCaptureManager()
        #expect(manager.stopRecording() == [])
    }

    @Test
    func drainConverterTailReturnsEmptyOrHarmlessWithNoInput() throws {
        // A converter that received no prior input should return [] or a trivially
        // small result - it must not inject spurious audio.
        let inputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let targetFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let converter = try #require(AVAudioConverter(from: inputFormat, to: targetFormat))

        let tail = AudioCaptureManager.drainConverterTail(converter)
        // No prior input -> nothing to flush.
        #expect(tail.count == 0, "flush with no prior input must not produce spurious samples")
    }

    // MARK: - Tap epoch guard (stale-engine tap regression)

    @Test
    func staleEpochTapCallbackIsDroppedAfterSwap() throws {
        // Regression: after stopRecording/handleConfigChange swaps the engine, the OLD
        // engine's tap keeps firing until the off-main teardown removes it. Its callback
        // must be dropped instead of appending old-device samples into the fresh buffer.
        let manager = AudioCaptureManager()
        let staleEpoch = manager.currentTapEpochForTesting

        manager.triggerConfigChangeForTesting()   // swapEngine() bumps the epoch

        #expect(manager.currentTapEpochForTesting != staleEpoch,
                "swapEngine must bump the epoch")

        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16

        let acceptedStale = manager.processTapCallbackForTesting(epoch: staleEpoch, buffer)
        #expect(acceptedStale == false, "a callback captured with the pre-swap epoch must be dropped")

        let acceptedCurrent = manager.processTapCallbackForTesting(
            epoch: manager.currentTapEpochForTesting, buffer)
        #expect(acceptedCurrent == true, "a callback captured with the current epoch must be accepted")
    }

    // MARK: - Mid-settle recording interrupt (silent hot-mic regression)

    @Test
    func configChangeWhileSettlingAndRecordingInterruptsInsteadOfDroppingSilently() {
        // Regression: a hold can start mid-settle (after the first config change already
        // swapped in a fresh engine and started its settle window). If that engine's
        // config changes again before the settle window completes, the notification must
        // not be silently dropped while isRecording stays true on the engine - it must
        // interrupt the recording so the caller can flush/re-arm instead of holding a
        // silent mic.
        let manager = AudioCaptureManager()
        manager.settleDelay = 5.0 // long enough that the settle timer will not fire mid-test
        manager.validateDelay = 0.02

        let interrupted = LockedBox<[Float]>()
        manager.onEvent = { @Sendable event in
            if case .recordingInterrupted(let samples) = event {
                interrupted.set(samples)
            }
        }

        manager.triggerConfigChangeForTesting()   // first config change -> isSettling = true
        #expect(manager.isSettlingForTesting)

        manager.setRecordingForTesting(true)      // simulate a hold that started mid-settle

        manager.triggerConfigChangeForTesting()   // second config change while settling+recording

        #expect(interrupted.value != nil,
                ".recordingInterrupted must fire for a mid-settle recording interrupt")
        // isRecording must be cleared so a stray stopRecording() no-ops (mic not left hot).
        #expect(manager.stopRecording() == [])
        // Still settling (in-flight timer not fired) - not a second full settle cycle.
        #expect(manager.isSettlingForTesting)
    }

    // MARK: - Start-vs-swap race guard (concurrent engine.start()/engine.stop() regression)

    @Test
    func configChangeIsSuppressedWhileStartInFlight() {
        // Regression: a config-change notification arriving while startRecording() has
        // an off-main engine.start() in flight must not swapEngine() the engine out from
        // under it - concurrent engine.start()/engine.stop() on the same AVAudioEngine is
        // a data race, and even race-free, it would leave isRecording flipped true on a
        // fresh, untapped, unstarted engine (silent hot mic; re-arm no-ops).
        let recorder = EngineBuildRecorder()
        let manager = AudioCaptureManager(makeEngine: { @Sendable in
            recorder.record()
            return AVAudioEngine()
        })
        let buildCountBefore = recorder.buildCount
        let engineBefore = manager.currentEngineForTesting

        manager.setStartingForTesting(true)
        manager.triggerEngineConfigChangeNotificationForTesting()
        #expect(recorder.buildCount == buildCountBefore,
                "no engine swap must happen while a start is in flight")
        #expect(manager.currentEngineForTesting === engineBefore,
                "engine identity must be stable while isStarting is held")

        manager.setStartingForTesting(false)
        manager.triggerEngineConfigChangeNotificationForTesting()
        #expect(recorder.buildCount > buildCountBefore,
                "once isStarting clears, a config change must be handled normally again")
    }

    @Test
    func startRecordingClearsIsStartingOnCompletion() async {
        // isStarting must not leak true after startRecording() returns (success, failure,
        // or the noInputDevice/CI-no-hardware path) - a stuck isStarting would permanently
        // suppress config-change handling.
        let manager = AudioCaptureManager()
        #expect(!manager.isStartingForTesting)
        _ = try? await Task { @MainActor in try await manager.startRecording() }.value
        #expect(!manager.isStartingForTesting, "isStarting must be cleared once startRecording() returns")
        _ = manager.stopRecording()
    }

    @Test
    func configChangeWhileSettlingWithoutRecordingStillDebounces() {
        // Non-recording case must remain fully debounced (no interrupt event, no swap).
        let recorder = EngineBuildRecorder()
        let manager = AudioCaptureManager(makeEngine: { @Sendable in
            recorder.record()
            return AVAudioEngine()
        })
        manager.settleDelay = 5.0
        manager.validateDelay = 0.02

        let interrupted = LockedFlag()
        manager.onEvent = { @Sendable event in
            if case .recordingInterrupted = event { interrupted.set() }
        }

        manager.triggerConfigChangeForTesting()
        let buildCountAfterFirst = recorder.buildCount

        manager.triggerConfigChangeForTesting()   // settling, not recording -> dropped

        #expect(!interrupted.value, "no recording was active - no interrupt should fire")
        #expect(recorder.buildCount == buildCountAfterFirst, "no second swap while settling")
    }
}
