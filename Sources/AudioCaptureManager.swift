import AVFoundation

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
    private var configChangeTimer: DispatchWorkItem?

    var onAudioLevel: ((Float) -> Void)?
    var onRecordingInterrupted: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigChange()
        }
    }

    func startRecording() async throws {
        guard !isRecording else { return }

        bufferLock.withLock { buffer.removeAll(keepingCapacity: true) }

        var lastError: Error = AudioCaptureError.noInputDevice
        for attempt in 1...5 {
            if isSettling {
                print("[dictate] Audio settling, waiting before attempt \(attempt)")
                try await Task.sleep(for: .milliseconds(500))
            }

            let inputNode = engine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)

            guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                throw AudioCaptureError.noInputDevice
            }

            // Pass nil so AVAudioEngine uses the native hardware format at install time.
            // Avoids the "Input HW format and tap format not matching" crash when the
            // format changes between our outputFormat() read and installTap().
            // Converter is created lazily in processAudioBuffer from the actual buffer format.
            converterLock.withLock { converter = nil }
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
                [weak self] pcmBuffer, _ in
                self?.processAudioBuffer(pcmBuffer)
            }

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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converterLock.withLock { converter = nil }
        if isRecording {
            print("[dictate] Audio config changed during recording")
            isRecording = false
            onRecordingInterrupted?()
        }
        isSettling = true
        configChangeTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isSettling = false }
        configChangeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

enum AudioCaptureError: Error {
    case noInputDevice
}
