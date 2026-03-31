import AVFoundation
import CoreAudio

final class AudioCaptureManager: @unchecked Sendable {
    private let engine = AVAudioEngine()
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

    var onAudioLevel: ((Float) -> Void)?
    var onRecordingInterrupted: (() -> Void)?
    var onDeviceChanged: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigChange()
        }
        installDefaultInputListener()
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
            // Only handle idle device changes; AVAudioEngineConfigurationChange covers the recording case.
            guard !self.isRecording else { return }
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
            // Engine already running - swap prime tap for recording tap
            isPriming = false
            engine.inputNode.removeTap(onBus: 0)
            installRecordingTap()
            isRecording = true
            print("[dictate] Recording started (primed)")
            return
        }

        var lastError: Error = AudioCaptureError.noInputDevice
        for attempt in 1...5 {
            if isSettling {
                print("[dictate] Audio settling, waiting before attempt \(attempt)")
                try await Task.sleep(for: .milliseconds(500))
            }

            let hwFormat = engine.inputNode.outputFormat(forBus: 0)
            guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                throw AudioCaptureError.noInputDevice
            }

            // Pass nil so AVAudioEngine uses the native hardware format at install time.
            // Avoids the "Input HW format and tap format not matching" crash when the
            // format changes between our outputFormat() read and installTap().
            // Converter is created lazily in processAudioBuffer from the actual buffer format.
            installRecordingTap()
            engine.prepare()
            do {
                try engine.start()
                isRecording = true
                print("[dictate] Recording started (attempt \(attempt))")
                return
            } catch {
                lastError = error
                engine.inputNode.removeTap(onBus: 0)
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
        print("[dictate] Captured \(captured.count) samples (\(String(format: "%.1f", duration))s)")
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
            print("[dictate] Conversion error: \(error)")
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
        onAudioLevel?(normalizedLevel)

        bufferLock.lock()
        buffer.append(contentsOf: samples)
        bufferLock.unlock()
    }

    private func handleConfigChange() {
        primeStopTimer?.cancel()
        primeStopTimer = nil
        isPriming = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        converterLock.withLock { converter = nil }
        if isRecording {
            print("[dictate] Audio config changed during recording")
            isRecording = false
            onRecordingInterrupted?()
        }
        isSettling = true
        configChangeTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isSettling = false
            self?.onDeviceChanged?()
        }
        configChangeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

enum AudioCaptureError: Error {
    case noInputDevice
}
