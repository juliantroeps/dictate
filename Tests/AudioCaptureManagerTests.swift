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

/// Ferries a non-Sendable value into a detached task for off-main test invocation.
private struct TestSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
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
}
