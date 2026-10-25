import Foundation
import Testing

@testable import DictateCore
@testable import dictate

struct EngineCoordinatorCaptureTests {
    private struct Boom: Error {}

    @MainActor
    private func makeCoordinator(
        engine: FakeTranscriptionEngine, directory: URL?
    ) -> EngineCoordinator {
        EngineCoordinator(
            settings: FakeEngineSettings(whisperModel: "capture-model"),
            overlay: FakeOverlayController(),
            engine: engine,
            captureRecorder: directory.map { CaptureRecorder(directory: $0) },
            captureDevice: { CaptureRecorder.InputDevice(name: "Test Mic", isBluetooth: true) })
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("captures-\(UUID().uuidString)")
    }

    /// Saving is fire-and-forget off the main actor, so wait for the sidecar to appear.
    @MainActor
    private func waitForSidecar(in directory: URL) async throws -> [String: Any] {
        for _ in 0..<200 {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if let json = files.first(where: { $0.hasSuffix(".json") }),
                files.contains(where: { $0.hasSuffix(".wav") }),
                let object = try? JSONSerialization.jsonObject(
                    with: Data(contentsOf: directory.appendingPathComponent(json))) as? [String: Any]
            {
                return object
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("no capture appeared in \(directory.path)")
        return [:]
    }

    @Test @MainActor
    func savesSamplesWithModelDeviceAndHypothesis() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = makeCoordinator(engine: FakeTranscriptionEngine(), directory: dir)

        let text = try await coordinator.transcribe(audioSamples: Array(repeating: 0.2, count: 3_200))
        #expect(text == "fake transcription")

        let sidecar = try await waitForSidecar(in: dir)
        #expect(sidecar["model"] as? String == "capture-model")
        #expect(sidecar["input_device"] as? String == "Test Mic")
        #expect(sidecar["bluetooth"] as? Bool == true)
        #expect(sidecar["hypothesis"] as? String == "fake transcription")
        #expect(sidecar["sample_count"] as? Int == 3_200)
        #expect(sidecar["error"] == nil)
    }

    @Test @MainActor
    func savesFailedTranscriptionsWithError() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeTranscriptionEngine()
        engine.transcribeError = Boom()
        let coordinator = makeCoordinator(engine: engine, directory: dir)

        do {
            _ = try await coordinator.transcribe(audioSamples: [0.1, 0.2])
            Issue.record("expected transcribe to throw")
        } catch is Boom {}

        let sidecar = try await waitForSidecar(in: dir)
        #expect(sidecar["hypothesis"] == nil)
        #expect((sidecar["error"] as? String)?.contains("Boom") == true)
    }

    @Test @MainActor
    func writesNothingWhenRecorderIsOff() async throws {
        let dir = tempDir()
        let coordinator = makeCoordinator(engine: FakeTranscriptionEngine(), directory: nil)

        _ = try await coordinator.transcribe(audioSamples: [0.1])
        try await Task.sleep(for: .milliseconds(100))

        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
