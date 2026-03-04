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
    private var promptTokens: [Int]?
    private let model: String

    var isReady: Bool { whisperKit != nil }

    init(model: String = "openai_whisper-small.en") {
        self.model = model
    }

    func prepare() async throws {
        guard whisperKit == nil else { return }
        print("[dikt] Loading WhisperKit model: \(model)")
        let config = WhisperKitConfig(model: model, load: true)
        let wk = try await WhisperKit(config)
        whisperKit = wk

        if let tokenizer = wk.tokenizer {
            let prompt = PromptProvider.resolve()
            let encoded = tokenizer.encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            promptTokens = encoded
            print("[dikt] Prompt encoded: \(encoded.count) tokens")
            if encoded.count > 224 {
                print("[dikt] WARNING: Prompt exceeds 224 tokens (\(encoded.count)), will be truncated by decoder")
            }
        } else {
            print("[dikt] WARNING: Tokenizer not available, skipping prompt conditioning")
        }

        print("[dikt] WhisperKit ready")
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let wk = whisperKit else {
            throw TranscriptionError.engineNotReady
        }

        var options = DecodingOptions()
        if let tokens = promptTokens {
            options.promptTokens = tokens
            options.usePrefillPrompt = true
        }

        let results = try await wk.transcribe(audioArray: audioSamples, decodeOptions: options)
        return results.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum TranscriptionError: Error {
    case engineNotReady
}
