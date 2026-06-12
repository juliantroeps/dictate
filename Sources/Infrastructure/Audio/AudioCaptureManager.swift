import AVFoundation
import CoreAudio

@MainActor
final class AudioCaptureManager {
    private var engine = AVAudioEngine()
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
    private var configChangeTimer: DispatchWorkItem?
    // Stored nonisolated(unsafe) so deinit (nonisolated) can read it to deregister.
    // Written once in init before any concurrent access.
    nonisolated(unsafe) private var inputListenerBlock: AudioObjectPropertyListenerBlock = { _, _ in }

    init() {
        setupEngineObserver()
        installDefaultInputListener()
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
                guard let self, !self.isSettling else { return }
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
                    // Skip during recording (AVAudioEngineConfigurationChange handles that)
                    // and during settling (prevents BT HFP re-trigger loop).
                    guard !self.isRecording, !self.isSettling else { return }
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

        bufferLock.withLock { buffer.removeAll(keepingCapacity: true) }

        var lastError: Error = AudioCaptureError.noInputDevice
        for attempt in 1...5 {
            installRecordingTap()
            engine.prepare()

            let hwFormat = engine.inputNode.outputFormat(forBus: 0)
            guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                engine.inputNode.removeTap(onBus: 0)
                throw AudioCaptureError.noInputDevice
            }

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

            do {
                try engine.start()
                isRecording = true
                AppLogger.audio.info("Recording started (attempt \(attempt))")
                return
            } catch {
                lastError = error
                engine.inputNode.removeTap(onBus: 0)
                AppLogger.audio.error(
                    "engine.start() failed attempt \(attempt): \(error)"
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

    private func installRecordingTap() {
        converterLock.withLock { converter = nil }
        // Unconditional remove: clears any stale tap before installing a fresh one.
        engine.inputNode.removeTap(onBus: 0)
        // @Sendable strips the MainActor isolation this closure would otherwise
        // inherit from its enclosing @MainActor context. AVFAudio invokes the tap
        // block on its realtime audio thread; an isolated closure would trap in
        // Swift 6's executor precondition (swift_task_isCurrentExecutor ->
        // dispatch_assert_queue_fail). processAudioBuffer is nonisolated, so this is safe.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable [weak self] pcmBuffer, _ in
            self?.processAudioBuffer(pcmBuffer)
        }
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

        // Swap in a fresh engine on main (cheap), then tear down the old one off-main.
        // removeTap/stop dispatch into AVFAudio's private queue; during BT churn that
        // queue can be busy and stall the main thread, delaying the Processing overlay
        // on the key-up critical path.
        let oldEngine = engine
        engine = AVAudioEngine()
        setupEngineObserver()
        converterLock.withLock { converter = nil }

        let box = UncheckedSendableBox(oldEngine)
        DispatchQueue.global(qos: .utility).async {
            let e = box.value
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }

        let duration = Double(captured.count) / 16_000.0
        AppLogger.audio.info("Captured \(captured.count) samples (\(String(format: "%.1f", duration))s)")
        return captured
    }

    // Internal so tests can exercise the guard without audio hardware.
    // nonisolated so processAudioBuffer (tap thread) can call it directly.
    nonisolated static func outputFrameCount(sampleRate: Double, inputFrames: AVAudioFrameCount) -> AVAudioFrameCount? {
        guard sampleRate > 0 else { return nil }   // 0 Hz during device transitions -> inf ratio -> UInt32 trap
        return AVAudioFrameCount(Double(inputFrames) * (16_000.0 / sampleRate))
    }

    // Internal so tests can exercise the flush without audio hardware.
    // Runs a single .endOfStream convert pass to drain the resampler tail
    // (filter group-delay latency + last partial frame) held in the converter.
    // nonisolated so stopRecording and handleConfigChange can call it from lock closures.
    nonisolated static func drainConverterTail(_ converter: AVAudioConverter) -> [Float] {
        // Tail is bounded (filter delay); a few hundred frames at 16kHz is ample.
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: 4096
        ) else { return [] }

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
        guard let outputFrameCount = AudioCaptureManager.outputFrameCount(
            sampleRate: inputBuffer.format.sampleRate,
            inputFrames: inputBuffer.frameLength
        ) else { return }

        let converter: AVAudioConverter? = converterLock.withLock {
            if self.converter == nil || self.converter!.inputFormat != inputBuffer.format {
                self.converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat)
            }
            return self.converter
        }
        guard let converter else { return }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCount
        ) else { return }

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
            AppLogger.audio.error("Conversion error: \(error)")
            return
        }

        guard let floatData = outputBuffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(
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

        // Swap in a fresh engine on main (cheap), then tear down the old one off-main.
        // removeTap/stop and -[AVAudioEngine dealloc] all dispatch synchronously into
        // AVFAudio's private queue; during a device transition that queue can be busy,
        // so running them on the main thread risks a permanent beachball. Buffer is
        // already snapshotted above; startRecording() clears the buffer before the
        // next take, so a late old-engine tap callback cannot pollute the next recording.
        let oldEngine = engine
        // Create new engine - reset() alone doesn't reinitialize for different devices
        engine = AVAudioEngine()
        setupEngineObserver()
        converterLock.withLock { converter = nil }

        let box = UncheckedSendableBox(oldEngine)
        DispatchQueue.global(qos: .utility).async {
            let e = box.value
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }

        if let capturedSamples {
            AppLogger.audio.debug("Audio config changed during recording, captured \(capturedSamples.count) samples")
            onEvent?(.recordingInterrupted(samples: capturedSamples))
        }

        // Debounce: coalesce rapid config changes (BT connect fires many).
        isSettling = true
        configChangeTimer?.cancel()
        AppLogger.audio.debug("Config change - settling")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.validateFormatStability { [weak self] stable in
                    guard let self else { return }
                    MainActor.assumeIsolated {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func captureBuffer() -> [Float] {
        bufferLock.lock()
        let captured = buffer
        buffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()
        return captured
    }

    private func validateFormatStability(completion: @escaping @Sendable (Bool) -> Void) {
        let format1 = engine.inputNode.outputFormat(forBus: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    completion(false)
                    return
                }
                let format2 = self.engine.inputNode.outputFormat(forBus: 0)
                let stable = format1.sampleRate == format2.sampleRate &&
                             format1.channelCount == format2.channelCount &&
                             format1.sampleRate > 0
                completion(stable)
            }
        }
    }
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
