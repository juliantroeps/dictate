import AVFoundation
import Foundation
import Testing

@testable import dictate

struct CaptureRecorderTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("captures-\(UUID().uuidString)")
    }

    @Test func offUnlessFlagIsExactlyOne() {
        #expect(CaptureRecorder.fromEnvironment([:]) == nil)
        #expect(CaptureRecorder.fromEnvironment([CaptureRecorder.environmentKey: "0"]) == nil)
        #expect(CaptureRecorder.fromEnvironment([CaptureRecorder.environmentKey: "true"]) == nil)
        #expect(CaptureRecorder.fromEnvironment([CaptureRecorder.environmentKey: "1"]) != nil)
    }

    @Test func wavHeaderDescribesMonoFloat32() {
        let data = CaptureRecorder.wavData(samples: [0.5, -0.25], sampleRate: 16_000)
        #expect(data.count == 56 + 8)
        #expect(String(bytes: data[0..<4], encoding: .utf8) == "RIFF")
        #expect(String(bytes: data[8..<12], encoding: .utf8) == "WAVE")
        func u32(_ offset: Int) -> UInt32 {
            data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        #expect(u32(4) == UInt32(data.count - 8))
        #expect(u32(44) == 2)  // fact chunk: frame count
        #expect(u32(52) == 8)  // data chunk size
    }

    @Test func writtenWavReadsBackBitExact() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples: [Float] = (0..<1_600).map { sin(Float($0) * 0.05) * 0.8 }
        let recorder = CaptureRecorder(directory: dir)
        let url = try recorder.write(
            samples: samples,
            sidecar: .init(
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), audioSeconds: 0.1, sampleCount: 1_600,
                sampleRate: 16_000, model: "m", inputDevice: "Mic", bluetooth: false, hypothesis: "hi", error: nil))

        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 16_000)
        #expect(file.processingFormat.channelCount == 1)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let read = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
        #expect(read == samples)
    }

    @Test func sidecarCarriesContextInSnakeCase() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = CaptureRecorder(directory: dir)
        let url = try recorder.write(
            samples: [0.1],
            sidecar: .init(
                timestamp: Date(timeIntervalSince1970: 0), audioSeconds: 1, sampleCount: 1, sampleRate: 16_000,
                model: "openai_whisper-small.en", inputDevice: "AirPods", bluetooth: true, hypothesis: nil,
                error: "timeout"))
        let json = try Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json"))
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["input_device"] as? String == "AirPods")
        #expect(object["bluetooth"] as? Bool == true)
        #expect(object["model"] as? String == "openai_whisper-small.en")
        #expect(object["error"] as? String == "timeout")
        #expect(object["hypothesis"] == nil)
        #expect(object["timestamp"] as? String == "1970-01-01T00:00:00Z")

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}
