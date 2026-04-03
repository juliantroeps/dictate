import AVFoundation
import CoreAudio

final class AudioCaptureManager: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var configChangeObserver: Any?
    private var resetGeneration = 0
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var buffer: [Float] = []
    private let bufferLock = NSLock()
    private let converterLock = NSLock()
    private var isRecording = false
    private var isSettling = false
    private var isPriming = false
    private var configChangeTimer: DispatchWorkItem?
    private var primeStopTimer: DispatchWorkItem?

    var onEvent: ((AudioCaptureEvent) -> Void)?

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
            guard let self, !self.isSettling else { return }
            self.handleConfigChange()
        }
    }

    deinit {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, nil, defaultInputListenerBlock
        )
    }

    private lazy var defaultInputListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Skip during recording (AVAudioEngineConfigurationChange handles that)
            // and during settling (prevents BT HFP re-trigger loop).
            guard !self.isRecording, !self.isSettling else { return }
            self.handleConfigChange()
        }
    }

    private func installDefaultInputListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, nil, defaultInputListenerBlock
        )
    }

    func primeInput() {
        guard !isRecording, !isSettling else { return }
        if isPriming {
            // Already priming - reset the stop timer to keep it alive longer
            primeStopTimer?.cancel()
            schedulePrimeStop()
            return
        }
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { _, _ in }
        engine.prepare()
        guard (try? engine.start()) != nil else {
            inputNode.removeTap(onBus: 0)
            return
        }
        isPriming = true
        schedulePrimeStop()
        AppLogger.audio.debug("Audio engine primed")
    }

    private func schedulePrimeStop() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPriming, !self.isRecording else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.isPriming = false
        }
        primeStopTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    func startRecording() async throws {
        guard !isRecording else { return }

        primeStopTimer?.cancel()
        primeStopTimer = nil
        bufferLock.withLock { buffer.removeAll(keepingCapacity: true) }

        if isPriming {
            isPriming = false
            engine.inputNode.removeTap(onBus: 0)
            installRecordingTap()
            isRecording = true
            AppLogger.audio.info("Recording started (primed)")
            return
        }

        var lastError: Error = AudioCaptureError.noInputDevice
        for attempt in 1...5 {
            // Wait for settling to finish - engine may be replaced multiple times
            // during this wait, that's fine since we haven't installed taps yet.
            while isSettling {
                AppLogger.audio.debug("Audio settling, waiting before attempt \(attempt)")
                try await Task.sleep(for: .milliseconds(300))
            }

            // Snapshot generation AFTER settling, right before touching the engine
            let gen = resetGeneration

            installRecordingTap()
            engine.prepare()

            // Engine reset between tap install and start - retry
            guard resetGeneration == gen else {
                AppLogger.audio.debug("Engine reset after tap install, retrying")
                continue
            }

            let hwFormat = engine.inputNode.outputFormat(forBus: 0)
            guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                engine.inputNode.removeTap(onBus: 0)
                throw AudioCaptureError.noInputDevice
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
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        throw lastError
    }

    private func installRecordingTap() {
        converterLock.withLock { converter = nil }
        // Defensive remove: if primeInput ran while startRecording was suspended (await), a tap is already installed.
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] pcmBuffer, _ in
            self?.processAudioBuffer(pcmBuffer)
        }
    }

    func stopRecording() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        bufferLock.lock()
        let captured = buffer
        buffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        let duration = Double(captured.count) / 16_000.0
        AppLogger.audio.info("Captured \(captured.count) samples (\(String(format: "%.1f", duration))s)")
        return captured
    }

    private func processAudioBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        let converter: AVAudioConverter? = converterLock.withLock {
            if self.converter == nil || self.converter!.inputFormat != inputBuffer.format {
                self.converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat)
            }
            return self.converter
        }
        guard let converter else { return }

        let ratio = 16_000.0 / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)

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
        onEvent?(.audioLevel(normalizedLevel))

        bufferLock.lock()
        buffer.append(contentsOf: samples)
        bufferLock.unlock()
    }

    private func handleConfigChange() {
        // Stop current activity immediately
        primeStopTimer?.cancel()
        primeStopTimer = nil
        isPriming = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Create new engine - reset() alone doesn't reinitialize for different devices
        engine = AVAudioEngine()
        setupEngineObserver()
        converterLock.withLock { converter = nil }
        resetGeneration += 1
        if isRecording {
            AppLogger.audio.debug("Audio config changed during recording")
            isRecording = false
            onEvent?(.recordingInterrupted)
        }

        // Debounce: coalesce rapid config changes (BT connect fires many).
        isSettling = true
        configChangeTimer?.cancel()
        AppLogger.audio.debug("Config change - settling")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.validateFormatStability { [weak self] stable in
                guard let self else { return }
                self.isSettling = false
                if !stable {
                    AppLogger.audio.debug("Format unstable after settling")
                }
                self.onEvent?(.inputConfigurationChanged(stable: stable))
            }
        }
        configChangeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func validateFormatStability(completion: @escaping @Sendable (Bool) -> Void) {
        let format1 = engine.inputNode.outputFormat(forBus: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
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

enum AudioCaptureError: Error {
    case noInputDevice
}
