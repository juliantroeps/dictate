import AVFoundation

final class AudioCaptureManager: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var buffer: [Float] = []
    private let bufferLock = NSLock()
    private var isRecording = false

    var onAudioLevel: ((Float) -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigChange()
        }
    }

    func startRecording() throws {
        guard !isRecording else { return }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        bufferLock.lock()
        buffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] pcmBuffer, _ in
            self?.processAudioBuffer(pcmBuffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        print("[dictate] Recording started")
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
        if isRecording {
            print("[dictate] Audio config changed during recording")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRecording = false
        }
    }
}

enum AudioCaptureError: Error {
    case noInputDevice
}
