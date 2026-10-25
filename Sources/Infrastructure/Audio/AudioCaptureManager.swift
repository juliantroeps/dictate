@preconcurrency import AVFoundation
import CoreAudio
import DictateCore

@MainActor
final class AudioCaptureManager {
    // Injectable so tests can record on which queue each engine is built and
    // assert construction never happens on the main thread during a config change.
    private let makeEngine: @Sendable () -> AVAudioEngine
    private var engine: AVAudioEngine
    // One serial queue per engine: every op touching it (tap install, start, rollback,
    // teardown) runs here, off main and never concurrently. inputNode lazily creates
    // the AUHAL unit via sync XPC to coreaudiod, which stalls >2s after wake/device churn.
    private var engineQueue: DispatchQueue
    // Whether the current engine's inputNode was ever touched (tap installed). An
    // untouched engine binds to whatever the default input is at first use, so it
    // never needs swapping on a device change.
    private var engineTapped = false
    // Idle config change on a tapped engine: swap lazily at the next start instead of
    // churning engines (build + off-main teardown) on every default-input change.
    private var engineStale = false
    private var configChangeObserver: Any?
    // targetFormat is immutable and accessed from the audio tap thread (nonisolated);
    // nonisolated(unsafe) is safe because it is set once in init and never mutated.
    nonisolated(unsafe) private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    // buffer/converter accessed from the audio tap thread under their respective locks.
    nonisolated(unsafe) var buffer: [Float] = []
    nonisolated(unsafe) var converter: AVAudioConverter?
    let bufferLock = NSLock()
    let converterLock = NSLock()
    // onEvent is assigned once at setup (before recording) and read from the tap thread;
    // the consumer re-hops to main (AppDelegate.swift), so a single-assignment
    // nonisolated(unsafe) is correct here.
    nonisolated(unsafe) var onEvent: ((AudioCaptureEvent) -> Void)?
    private var isRecording = false
    private var isSettling = false
    // True for the whole span of startRecording(): prevents a config-change
    // notification from calling swapEngine() while performEngineStart is running
    // engine.start() off-main on that same engine. Teardown is serialized after the
    // start on the engine's queue, but without this guard self.engine
    // would already point at a fresh untapped/unstarted engine by the time the await
    // resumes, so flipping isRecording=true would mark a dead engine as recording
    // (silent hot mic, re-arm no-ops via guard !isRecording).
    private var isStarting = false
    private var configChangeTimer: DispatchWorkItem?
    // Stored nonisolated(unsafe) so deinit (nonisolated) can read it to deregister.
    // Written once in init before any concurrent access.
    nonisolated(unsafe) private var inputListenerBlock: AudioObjectPropertyListenerBlock = { _, _ in }

    // Guards against a stale engine's tap: after swapEngine, the OLD engine keeps
    // firing its installTap callback until the off-main teardown runs removeTap.
    // Each tap closure captures the epoch current at install time; swapEngine bumps
    // the epoch, so a lingering old-engine callback fails isCurrentEpoch and is
    // dropped instead of appending old-device samples into the new self.buffer.
    private let epochLock = NSLock()
    nonisolated(unsafe) private var _tapEpoch: UInt64 = 0

    private var currentEpoch: UInt64 {
        epochLock.withLock { _tapEpoch }
    }

    private func bumpEpoch() {
        epochLock.withLock { _tapEpoch += 1 }
    }

    // nonisolated so the tap closure (audio render thread) can call it directly.
    nonisolated private func isCurrentEpoch(_ epoch: UInt64) -> Bool {
        epochLock.withLock { _tapEpoch == epoch }
    }

    #if DEBUG
        // Test-only timing seam: lets tests shrink the settle/validate windows so the
        // full config-change lifecycle can be exercised without a ~1.8s real-time sleep.
        var settleDelay: TimeInterval = 1.5
        var validateDelay: TimeInterval = 0.2
    #else
        private let settleDelay: TimeInterval = 1.5
        private let validateDelay: TimeInterval = 0.2
    #endif

    init(makeEngine: @escaping @Sendable () -> AVAudioEngine = { AVAudioEngine() }) {
        self.makeEngine = makeEngine
        self.engine = makeEngine()  // initial build on init is fine (no device churn yet)
        self.engineQueue = Self.makeEngineQueue()
        setupEngineObserver()
        installDefaultInputListener()
    }

    /// Atomically swap to a freshly built engine ON MAIN (so callers and the next
    /// startRecording() always see a fresh, tap-free engine the instant they return -
    /// no start/stop race), then tear the OLD engine down OFF MAIN. removeTap/stop and
    /// -[AVAudioEngine dealloc] each dispatch SYNCHRONOUSLY into AVFAudio's private
    /// queue; during a device transition that queue is busy, so running them on main
    /// deadlocks the UI (permanent beachball). AVAudioEngine() construction is cheap
    /// and does not hit that queue the way teardown does, so it stays on main to keep
    /// the swap atomic and race-free.
    private func swapEngine() {
        // Bump first: any tap closure already installed on oldEngine captured the
        // pre-bump epoch, so it goes stale immediately - before the old engine's
        // (still-live) tap can fire again and pollute the fresh buffer/converter.
        bumpEpoch()
        let oldEngine = engine
        let oldQueue = engineQueue
        engine = makeEngine()
        engineQueue = Self.makeEngineQueue()
        let oldTapped = engineTapped
        engineTapped = false
        engineStale = false
        setupEngineObserver()
        converterLock.withLock { converter = nil }
        tearDownOffMain(oldEngine, on: oldQueue, tapped: oldTapped)
    }

    private static func makeEngineQueue() -> DispatchQueue {
        DispatchQueue(label: "dictate.audio.engine", qos: .userInitiated)
    }

    /// Hand the old engine's full teardown to its own serial queue (ordered after any
    /// pending start/rollback on it, separate from the new engine's queue). removeTap/stop
    /// and the final dealloc all block on AVFAudio's private queue; off-main they block
    /// harmlessly. An untouched engine skips inputNode entirely (accessing it would
    /// create the AUHAL unit just to tear it down).
    private func tearDownOffMain(_ oldEngine: AVAudioEngine, on queue: DispatchQueue, tapped: Bool) {
        let box = UncheckedSendableBox(oldEngine)
        queue.async {
            if tapped {
                box.value.inputNode.removeTap(onBus: 0)
                box.value.stop()
            }
            // Hold the last strong ref ~1s so AVFAudio blocks still queued for this
            // engine finish before dealloc (suspected EXC_BAD_ACCESS, Sentry 154550374).
            queue.asyncAfter(deadline: .now() + 1) { withExtendedLifetime(box) {} }
        }
    }

    private func setupEngineObserver() {
        if let old = configChangeObserver {
            NotificationCenter.default.removeObserver(old)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Never swap out from under an in-flight startRecording() - see isStarting.
                guard !self.isStarting else { return }
                // Normally debounce reentrant config changes while settling. But if a
                // hold started mid-settle and is now recording, still let this through -
                // handleConfigChange's isSettling branch will interrupt the recording
                // instead of leaving isRecording stuck true on a soon-to-be-dead engine.
                guard !self.isSettling || self.isRecording else { return }
                self.handleConfigChange()
            }
        }
    }

    deinit {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, nil, inputListenerBlock
        )
    }

    private func installDefaultInputListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Skip during recording (AVAudioEngineConfigurationChange handles that),
                    // during settling (prevents BT HFP re-trigger loop), and while a start is
                    // in flight (never swap out from under it - see isStarting).
                    guard !self.isRecording, !self.isSettling, !self.isStarting else { return }
                    self.handleConfigChange()
                }
            }
        }
        // Store the block so deinit can pass the same pointer to AudioObjectRemovePropertyListenerBlock.
        inputListenerBlock = listenerBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, nil, listenerBlock
        )
    }

    func startRecording() async throws {
        guard !isRecording else { return }

        // Held for the whole attempt loop so no config-change notification can
        // swapEngine() the engine currently being started off-main - see isStarting.
        isStarting = true
        defer { isStarting = false }

        bufferLock.withLock { buffer.removeAll(keepingCapacity: true) }
        if engineStale { swapEngine() }

        var lastError: Error = AudioCaptureError.noInputDevice
        for attempt in 1...5 {
            // A key-up cancel may have landed during the retry-backoff sleep after
            // stopRecording() already no-op'd (isRecording was still false). Bail out
            // before touching the engine so the mic does not stay hot. handleKeyUp's
            // stopRecording() already ran and will not run again.
            try Task.checkCancellation()

            converterLock.withLock { converter = nil }
            let tap = makeTapBlock()
            engineTapped = true
            #if DEBUG
                lastTappedEngine = engine
            #endif

            // Tap install + prepare() + the format probe + engine.start() are blocking
            // HAL calls that can stall while a device is mid-transition; run them on the
            // engine's queue so a key-press during wake/BT churn does not hang main.
            let outcome = await performEngineStart(engine, on: engineQueue, tap: tap)

            if Task.isCancelled, case .started = outcome {
                // Cancelled while the off-main start was in flight - roll back so a
                // fast key-up race does not leave the mic hot.
                rollBack(engine, on: engineQueue)
                throw CancellationError()
            }

            switch outcome {
            case .started:
                isRecording = true
                AppLogger.audio.info("Recording started (attempt \(attempt))")
                return
            case .noInputDevice:
                throw AudioCaptureError.noInputDevice
            case .failed(let box):
                lastError = box.value
                AppLogger.audio.error(
                    "engine.start() failed attempt \(attempt): \(box.value)"
                )
                if attempt < 5 {
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                    } catch {
                        // Sleep cancelled -> propagate, do not retry with a hot/half-set engine.
                        throw CancellationError()
                    }
                }
            }
        }
        throw lastError
    }

    /// Outcome of an off-main engine-start attempt (see performEngineStart).
    private enum EngineStartOutcome: Sendable {
        case started
        case noInputDevice
        case failed(UncheckedSendableBox<Error>)
    }

    private typealias TapBlock = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    /// Runs tap install + prepare() + the input-format probe + engine.start() on the
    /// engine's serial queue for a single attempt; removes the tap again on failure.
    /// nonisolated so the await genuinely leaves the main executor.
    nonisolated private func performEngineStart(
        _ engine: AVAudioEngine, on queue: DispatchQueue, tap: @escaping TapBlock
    ) async -> EngineStartOutcome {
        let box = UncheckedSendableBox(engine)
        return await withCheckedContinuation { continuation in
            queue.async {
                let engine = box.value
                let input = engine.inputNode
                // Unconditional remove: clears any stale tap before installing a fresh one.
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tap)
                engine.prepare()

                let hwFormat = input.outputFormat(forBus: 0)
                guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                    input.removeTap(onBus: 0)
                    continuation.resume(returning: .noInputDevice)
                    return
                }

                do {
                    try engine.start()
                    continuation.resume(returning: .started)
                } catch {
                    input.removeTap(onBus: 0)
                    continuation.resume(returning: .failed(UncheckedSendableBox(error)))
                }
            }
        }
    }

    private func rollBack(_ engine: AVAudioEngine, on queue: DispatchQueue) {
        let box = UncheckedSendableBox(engine)
        queue.async {
            box.value.stop()
            box.value.inputNode.removeTap(onBus: 0)
        }
    }

    /// Built on main so it captures the epoch current at install time: if swapEngine
    /// bumps the epoch before this tap's engine is torn down, its callbacks fail
    /// isCurrentEpoch and are dropped instead of appending stale-engine samples.
    private func makeTapBlock() -> TapBlock {
        let epoch = currentEpoch
        // @Sendable strips the MainActor isolation this closure would otherwise
        // inherit from its enclosing @MainActor context. AVFAudio invokes the tap
        // block on its realtime audio thread; an isolated closure would trap in
        // Swift 6's executor precondition (swift_task_isCurrentExecutor ->
        // dispatch_assert_queue_fail). processAudioBuffer is nonisolated, so this is safe.
        return { @Sendable [weak self] pcmBuffer, _ in
            guard let self, self.isCurrentEpoch(epoch) else { return }
            self.processAudioBuffer(pcmBuffer)
        }
    }

    func stopRecording() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false

        // Snapshot buffer on main before handing off the engine, so no late tap
        // callback can pollute it after we return.
        let captured = captureBuffer()

        // Atomically swap to a fresh engine on main, then tear down the old one
        // off-main; removeTap/stop/dealloc dispatch into AVFAudio's private queue,
        // which stalls main during device churn. Construction is cheap and stays
        // on main so the swap is atomic/race-free.
        swapEngine()

        let duration = Double(captured.count) / 16_000.0
        AppLogger.audio.info("Captured \(captured.count) samples (\(String(format: "%.1f", duration))s)")
        return captured
    }

    // Internal so tests can exercise the guard without audio hardware.
    // nonisolated so processAudioBuffer (tap thread) can call it directly.
    nonisolated static func outputFrameCount(sampleRate: Double, inputFrames: AVAudioFrameCount) -> AVAudioFrameCount? {
        guard sampleRate > 0 else { return nil }  // 0 Hz during device transitions -> inf ratio -> UInt32 trap
        return AVAudioFrameCount(Double(inputFrames) * (16_000.0 / sampleRate))
    }

    // Runs on the audio tap thread - must be nonisolated.
    // All state access is via bufferLock/converterLock or nonisolated(unsafe) targetFormat.
    nonisolated func processAudioBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard
            let outputFrameCount = AudioCaptureManager.outputFrameCount(
                sampleRate: inputBuffer.format.sampleRate,
                inputFrames: inputBuffer.frameLength
            )
        else { return }

        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            )
        else { return }

        var error: NSError?
        var inputConsumed = false

        // Hold converterLock across convert: main resets the converter (new recording,
        // engine swap) while a tap callback may still be in flight.
        let converted: Bool = converterLock.withLock {
            if self.converter == nil || self.converter!.inputFormat != inputBuffer.format {
                self.converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat)
            }
            guard let converter = self.converter else { return false }
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            return true
        }
        guard converted else { return }

        if let error {
            // Do not log (OSLog + fputs + Sentry capture) from the realtime render
            // thread. Format the message here (Sendable String), then hop the
            // actual report to main instead of carrying the non-Sendable NSError.
            let message = "Conversion error: \(error)"
            DispatchQueue.main.async {
                AppLogger.audio.error(message)
            }
            return
        }

        guard let floatData = outputBuffer.floatChannelData?[0] else { return }
        let samples = Array(
            UnsafeBufferPointer(
                start: floatData,
                count: Int(outputBuffer.frameLength)
            ))

        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        let rms = sqrt(sumOfSquares / max(Float(samples.count), 1))
        let normalizedLevel = min(rms * 12, 1.0)
        // onEvent is nonisolated(unsafe) - assigned once at setup, read here from tap thread.
        // Consumer (AppDelegate) re-hops to main via Task { @MainActor }.
        onEvent?(.audioLevel(normalizedLevel))

        bufferLock.lock()
        buffer.append(contentsOf: samples)
        bufferLock.unlock()
    }

    private func handleConfigChange() {
        // Reentrancy while already settling (BT churn fires many notifications, or a
        // hold started mid-settle and the newly-swapped engine's config changed again).
        // Debounce the swap/validate part - the in-flight settle timer still owns that
        // and will still deliver .inputConfigurationChanged when it completes - but do
        // not silently drop a live recording: without this, isRecording would stay true
        // on an engine nobody will ever swap out of settling again (silent hot mic).
        if isSettling {
            guard isRecording else { return }
            let capturedSamples = captureBuffer()
            isRecording = false
            // Tear the recording engine down (off-main) even while debouncing the
            // settle/validate cycle. Without this the engine stays started with a live
            // tap: if the user releases before the in-flight settle completes,
            // stopRecording() no-ops on isRecording == false and nothing ever swaps the
            // engine, leaving the mic hot and buffer growing until the next dictation.
            // swapEngine bumps the epoch (old tap stops appending) and does not start a
            // second settle cycle - the in-flight timer still owns that.
            swapEngine()
            AppLogger.audio.debug("Config changed mid-settle, captured \(capturedSamples.count) samples")
            onEvent?(.recordingInterrupted(samples: capturedSamples))
            return
        }
        isSettling = true
        configChangeTimer?.cancel()

        // Snapshot the buffer on main before handing off the old engine so a late
        // tap callback from the old engine cannot pollute the next recording.
        let capturedSamples: [Float]? = isRecording ? captureBuffer() : nil
        if capturedSamples != nil {
            isRecording = false
            swapEngine()
        } else if engineTapped {
            // Idle: no engine churn. Swap lazily at the next start (see engineStale).
            engineStale = true
        }

        if let capturedSamples {
            AppLogger.audio.debug("Audio config changed during recording, captured \(capturedSamples.count) samples")
            onEvent?(.recordingInterrupted(samples: capturedSamples))
        }

        // Debounce: coalesce rapid config changes (BT connect fires many).
        // (isSettling already set at top of handleConfigChange.)
        AppLogger.audio.debug("Config change - settling")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.validateFormatStability { [weak self] stable in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        // Always clear the settle gate first so no later branch can leave config-change
                        // handling permanently suppressed. Completion is guaranteed on main (Step 1).
                        self.isSettling = false
                        if !stable {
                            AppLogger.audio.debug("Format unstable after settling")
                        }
                        self.onEvent?(.inputConfigurationChanged(stable: stable))
                    }
                }
            }
        }
        configChangeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    private func captureBuffer() -> [Float] {
        bufferLock.lock()
        let captured = buffer
        buffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()
        return captured
    }

    private func validateFormatStability(completion: @escaping @Sendable (Bool) -> Void) {
        // Probes the default input device via CoreAudio instead of engine.inputNode, so
        // validation never touches (or lazily creates the IO unit of) a just-swapped
        // engine. HAL reads can stall mid-transition, so they stay off main. The
        // completion mutates main-actor state at the call site, so hop back to main
        // before invoking it (off-main completion + MainActor.assumeIsolated -> fatal trap).
        let validateDelay = self.validateDelay
        DispatchQueue.global(qos: .userInitiated).async {
            let first = Self.defaultInputProbe()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + validateDelay) {
                let second = Self.defaultInputProbe()
                let stable = first != nil && first == second
                DispatchQueue.main.async { completion(stable) }
            }
        }
    }

    private struct InputProbe: Equatable {
        let deviceID: AudioDeviceID
        let sampleRate: Double
    }

    /// Default input device + nominal sample rate, or nil if none / rate unknown.
    nonisolated private static func defaultInputProbe() -> InputProbe? {
        guard let deviceID = SystemAudioController.defaultInputDeviceID,
            let rate = SystemAudioController.nominalSampleRate(for: deviceID), rate > 0
        else { return nil }
        return InputProbe(deviceID: deviceID, sampleRate: rate)
    }

    #if DEBUG
        /// Test-only entry point: drives the config-change teardown/swap path so the
        /// off-main construction guarantee can be asserted without audio hardware.
        func triggerConfigChangeForTesting() { handleConfigChange() }

        /// Identity of the engine the most recent tap was installed on (test-only).
        weak var lastTappedEngine: AVAudioEngine?

        /// Identity of the currently installed engine (test-only).
        var currentEngineForTesting: AVAudioEngine { engine }

        /// Current tap epoch (test-only). See _tapEpoch.
        var currentTapEpochForTesting: UInt64 { currentEpoch }

        /// Runs the same isCurrentEpoch guard the real tap closure uses, then
        /// processAudioBuffer, returning whether the callback was accepted
        /// (test-only - lets the epoch guard be exercised without audio hardware).
        func processTapCallbackForTesting(epoch: UInt64, _ buffer: AVAudioPCMBuffer) -> Bool {
            guard isCurrentEpoch(epoch) else { return false }
            processAudioBuffer(buffer)
            return true
        }

        /// Marks the current engine as tapped (test-only - simulates a prior start attempt).
        func markEngineTappedForTesting() { engineTapped = true }

        /// Forces isRecording (test-only - simulates a hold that started mid-settle).
        func setRecordingForTesting(_ value: Bool) { isRecording = value }

        /// Whether a config-change settle window is in flight (test-only).
        var isSettlingForTesting: Bool { isSettling }

        /// Forces isStarting (test-only - simulates a startRecording() attempt in flight,
        /// without needing to race the real off-main engine.start() call).
        func setStartingForTesting(_ value: Bool) { isStarting = value }

        /// Whether a startRecording() attempt is currently in flight (test-only).
        var isStartingForTesting: Bool { isStarting }

        /// Mirrors the AVAudioEngineConfigurationChange observer's guard chain (including
        /// the isStarting check) so the start-vs-swap race guard can be asserted without
        /// posting a real NotificationCenter notification (test-only).
        func triggerEngineConfigChangeNotificationForTesting() {
            guard !isStarting else { return }
            guard !isSettling || isRecording else { return }
            handleConfigChange()
        }
    #endif
}

enum AudioCaptureError: Error {
    case noInputDevice
}

/// Carries a non-Sendable value across a concurrency boundary so a deferred
/// release can run off the main thread under Swift 6 strict concurrency.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
