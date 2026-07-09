@preconcurrency import AVFoundation
import CoreAudio

@MainActor
final class AudioCaptureManager {
    // Injectable so tests can record on which queue each engine is built and
    // assert construction never happens on the main thread during a config change.
    private let makeEngine: @Sendable () -> AVAudioEngine
    private var engine: AVAudioEngine
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
    // engine.start() off-main on that same engine. Without this guard, swapEngine's
    // off-main teardown (engine.stop()/removeTap on a .utility queue) could run
    // CONCURRENTLY with engine.start() on the .userInitiated queue - AVAudioEngine is
    // not thread-safe, so that is a data race, and even if it didn't crash, self.engine
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
        engine = makeEngine()
        setupEngineObserver()
        converterLock.withLock { converter = nil }
        tearDownOffMain(oldEngine)
    }

    /// Hand the old engine's full teardown to a background queue. removeTap/stop and the
    /// final dealloc all block on AVFAudio's private queue; off-main they block harmlessly.
    private func tearDownOffMain(_ oldEngine: AVAudioEngine) {
        let box = UncheckedSendableBox(oldEngine)
        DispatchQueue.global(qos: .utility).async {
            let engine = box.value
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            // `engine` (last strong ref) is released here, off-main -> dealloc blocks off-main.
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

        var lastError: Error = AudioCaptureError.noInputDevice
        for attempt in 1...5 {
            installRecordingTap()

            // A key-up cancel may have landed during the retry-backoff sleep after
            // stopRecording() already no-op'd (isRecording was still false). Bail out
            // before starting the engine so the mic does not stay hot. handleKeyUp's
            // stopRecording() already ran and will not run again.
            do {
                try Task.checkCancellation()
            } catch {
                engine.inputNode.removeTap(onBus: 0)
                throw CancellationError()
            }

            // prepare() + the format probe + engine.start() are blocking HAL calls
            // that can stall while a device is mid-transition (same class of stall
            // validateFormatStability already documents); run them off main so a
            // key-press during BT churn does not beachball the UI / delay the tap.
            let outcome = await performEngineStart(engine)

            if Task.isCancelled, case .started = outcome {
                // Cancelled while the off-main start was in flight - roll back so a
                // fast key-up race does not leave the mic hot.
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                throw CancellationError()
            }

            switch outcome {
            case .started:
                isRecording = true
                AppLogger.audio.info("Recording started (attempt \(attempt))")
                return
            case .noInputDevice:
                engine.inputNode.removeTap(onBus: 0)
                throw AudioCaptureError.noInputDevice
            case .failed(let box):
                lastError = box.value
                engine.inputNode.removeTap(onBus: 0)
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

    /// Runs prepare() + the input-format probe + engine.start() off the main actor
    /// for a single attempt. nonisolated so the dispatch genuinely leaves the main
    /// executor (an actor-isolated async func would just resume back on MainActor
    /// without ever running its body elsewhere).
    nonisolated private func performEngineStart(_ engine: AVAudioEngine) async -> EngineStartOutcome {
        let box = UncheckedSendableBox(engine)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let engine = box.value
                engine.prepare()

                let hwFormat = engine.inputNode.outputFormat(forBus: 0)
                guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                    continuation.resume(returning: .noInputDevice)
                    return
                }

                do {
                    try engine.start()
                    continuation.resume(returning: .started)
                } catch {
                    continuation.resume(returning: .failed(UncheckedSendableBox(error)))
                }
            }
        }
    }

    private func installRecordingTap() {
        converterLock.withLock { converter = nil }
        // Unconditional remove: clears any stale tap before installing a fresh one.
        engine.inputNode.removeTap(onBus: 0)
        // Captured at install time: if swapEngine bumps the epoch before this
        // closure's engine is torn down, its callbacks fail isCurrentEpoch and are
        // dropped instead of appending stale-engine samples into the fresh buffer.
        let epoch = currentEpoch
        // @Sendable strips the MainActor isolation this closure would otherwise
        // inherit from its enclosing @MainActor context. AVFAudio invokes the tap
        // block on its realtime audio thread; an isolated closure would trap in
        // Swift 6's executor precondition (swift_task_isCurrentExecutor ->
        // dispatch_assert_queue_fail). processAudioBuffer is nonisolated, so this is safe.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable [weak self] pcmBuffer, _ in
            guard let self, self.isCurrentEpoch(epoch) else { return }
            self.processAudioBuffer(pcmBuffer)
        }
        #if DEBUG
            lastTappedEngine = engine
        #endif
    }

    func stopRecording() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false

        // Snapshot buffer on main before handing off the engine, so no late tap
        // callback can pollute it after we return.
        bufferLock.lock()
        var captured = buffer
        buffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        // Drain the resampler tail before discarding the converter, so the SRC
        // filter-delay latency + final partial frame are not dropped.
        let tail: [Float] = converterLock.withLock {
            guard let converter else { return [] }
            return AudioCaptureManager.drainConverterTail(converter)
        }
        captured.append(contentsOf: tail)

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

    // Internal so tests can exercise the flush without audio hardware.
    // Runs a single .endOfStream convert pass to drain the resampler tail
    // (filter group-delay latency + last partial frame) held in the converter.
    // nonisolated so stopRecording and handleConfigChange can call it from lock closures.
    nonisolated static func drainConverterTail(_ converter: AVAudioConverter) -> [Float] {
        // Tail is bounded (filter delay); a few hundred frames at 16kHz is ample.
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: 4096
            )
        else { return [] }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if let error {
            AppLogger.audio.error("Converter flush error: \(error)")
            return []
        }
        guard let floatData = outputBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength)))
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

        let converter: AVAudioConverter? = converterLock.withLock {
            if self.converter == nil || self.converter!.inputFormat != inputBuffer.format {
                self.converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat)
            }
            return self.converter
        }
        guard let converter else { return }

        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: outputFrameCount
            )
        else { return }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

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
            var capturedSamples = captureBuffer()
            isRecording = false
            let tail: [Float] = converterLock.withLock {
                guard let converter else { return [] }
                return AudioCaptureManager.drainConverterTail(converter)
            }
            capturedSamples.append(contentsOf: tail)
            AppLogger.audio.debug("Config changed mid-settle, captured \(capturedSamples.count) samples")
            onEvent?(.recordingInterrupted(samples: capturedSamples))
            return
        }
        isSettling = true
        configChangeTimer?.cancel()

        // Snapshot the buffer on main before handing off the old engine so a late
        // tap callback from the old engine cannot pollute the next recording.
        var capturedSamples: [Float]? = isRecording ? captureBuffer() : nil
        if capturedSamples != nil {
            isRecording = false
            // Drain the resampler tail before discarding the converter, so the SRC
            // filter-delay latency + final partial frame are not dropped.
            let tail: [Float] = converterLock.withLock {
                guard let converter else { return [] }
                return AudioCaptureManager.drainConverterTail(converter)
            }
            capturedSamples?.append(contentsOf: tail)
        }

        swapEngine()

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
        // outputFormat(forBus:) queries the HAL synchronously and can stall while a
        // device is still transitioning; read it off the main thread on both samples.
        // The completion mutates main-actor state at the call site, so hop back to main
        // before invoking it (off-main completion + MainActor.assumeIsolated -> fatal trap).
        let engineBox = UncheckedSendableBox(engine)
        let validateDelay = self.validateDelay
        DispatchQueue.global(qos: .userInitiated).async {
            let format1 = engineBox.value.inputNode.outputFormat(forBus: 0)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + validateDelay) {
                let format2 = engineBox.value.inputNode.outputFormat(forBus: 0)
                let stable =
                    format1.sampleRate == format2.sampleRate && format1.channelCount == format2.channelCount
                    && format1.sampleRate > 0
                DispatchQueue.main.async { completion(stable) }
            }
        }
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
