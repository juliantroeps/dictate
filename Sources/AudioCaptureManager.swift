import AVFoundation
import CoreAudio

final class AudioCaptureManager: @unchecked Sendable {
    private var engine = AVAudioEngine()
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
    private var originalDefaultInput: AudioDeviceID?

    var onAudioLevel: ((Float) -> Void)?
    var onRecordingInterrupted: (() -> Void)?
    var onDeviceChanged: (() -> Void)?

    init() {
        registerEngineObserver()
    }

    func cleanup() {
        if let original = originalDefaultInput {
            originalDefaultInput = nil
            setSystemDefaultInputDevice(original)
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

    @MainActor
    func startRecording() async throws {
        guard !isRecording else { return }

        primeStopTimer?.cancel()
        primeStopTimer = nil
        bufferLock.withLock { buffer.removeAll(keepingCapacity: true) }

        guard let nonBTDeviceID = findNonBluetoothInputDevice() else {
            throw AudioCaptureError.noInputDevice
        }

        // Redirect system default input to non-BT device to keep BT headphones in A2DP.
        if originalDefaultInput == nil {
            if let current = getSystemDefaultInputDevice(), current != nonBTDeviceID {
                if setSystemDefaultInputDevice(nonBTDeviceID) {
                    originalDefaultInput = current
                }
            }
        }

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
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] pcmBuffer, _ in
            self?.processAudioBuffer(pcmBuffer)
        }
    }

    @MainActor
    func stopRecording() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Restore original default input now that recording is done.
        if let original = originalDefaultInput {
            originalDefaultInput = nil
            setSystemDefaultInputDevice(original)
        }

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
        onAudioLevel?(min(rms * 12, 1.0))

        bufferLock.lock()
        buffer.append(contentsOf: samples)
        bufferLock.unlock()
    }

    private func handleConfigChange() {
        primeStopTimer?.cancel()
        primeStopTimer = nil
        isPriming = false
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            isRecording = false
            onRecordingInterrupted?()
        }
        // Clear redirect state - don't restore here, we can't distinguish our own redirect's
        // config change from external events. stopRecording() restores after normal recording;
        // cleanup() restores on app quit.
        originalDefaultInput = nil
        // Recreate engine completely - fresh state, fresh format, no stale device info.
        recreateEngine()
        converterLock.withLock { converter = nil }
        isSettling = true
        configChangeTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isSettling = false
            self?.onDeviceChanged?()
        }
        configChangeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func recreateEngine() {
        NotificationCenter.default.removeObserver(
            self, name: .AVAudioEngineConfigurationChange, object: engine
        )
        engine = AVAudioEngine()
        registerEngineObserver()
    }

    private func registerEngineObserver() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigChange()
        }
    }

    // MARK: - Device helpers

    private func getSystemDefaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else { return nil }
        return deviceID
    }

    @discardableResult
    private func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status != noErr { print("[dictate] Failed to set default input device: \(status)") }
        return status == noErr
    }

    private func findNonBluetoothInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }

        var externalNonBT: AudioDeviceID?
        var builtIn: AudioDeviceID?

        for id in ids.sorted() {
            guard hasInputChannels(id), !isBluetoothDevice(id) else { continue }
            if isExternalNonBT(id) {
                if externalNonBT == nil { externalNonBT = id }
            } else if isBuiltIn(id) {
                if builtIn == nil { builtIn = id }
            }
        }
        return externalNonBT ?? builtIn
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        inputChannelCount(deviceID) > 0
    }

    private func inputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        let ablPtr = ptr.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ablPtr) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(ablPtr).reduce(0) { $0 + $1.mNumberChannels }
    }

    private func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return transport
    }

    private func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        let t = transportType(deviceID)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    private func isBuiltIn(_ deviceID: AudioDeviceID) -> Bool {
        transportType(deviceID) == kAudioDeviceTransportTypeBuiltIn
    }

    private func isExternalNonBT(_ deviceID: AudioDeviceID) -> Bool {
        let external: Set<UInt32> = [
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypePCI
        ]
        return external.contains(transportType(deviceID))
    }
}

enum AudioCaptureError: Error {
    case noInputDevice
}
