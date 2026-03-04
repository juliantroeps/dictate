import Foundation
import WhisperKit

// MARK: - Protocol

protocol TranscriptionEngine: Sendable {
    var name: String { get }
    var isReady: Bool { get }
    func prepare() async throws
    func transcribe(audioSamples: [Float]) async throws -> String
}

// MARK: - WhisperKitEngine

final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "WhisperKit"
    private var whisperKit: WhisperKit?
    private let model: String

    var isReady: Bool { whisperKit != nil }

    init(model: String = "openai_whisper-small.en") {
        self.model = model
    }

    func prepare() async throws {
        guard whisperKit == nil else { return }
        print("[dikt] Loading WhisperKit model: \(model)")
        whisperKit = try await WhisperKit(model: model)
        print("[dikt] WhisperKit ready")
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let wk = whisperKit else {
            throw TranscriptionError.engineNotReady
        }
        let results = await wk.transcribe(audioArrays: [audioSamples])
        return results.first??.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum TranscriptionError: Error {
    case engineNotReady
}
