import Foundation
import WhisperKit

// MARK: - Protocol

protocol TranscriptionEngine: Sendable {
    var name: String { get }
    var isReady: Bool { get }
    func prepare() async throws
    func transcribe(audioSamples: [Float]) async throws -> String
    func unload()
}

// MARK: - WhisperKitEngine

final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "WhisperKit"
    private var whisperKit: WhisperKit?
    private var promptTokens: [Int]?
    private let model: String

    var isReady: Bool { whisperKit != nil }

    init(model: String = "openai_whisper-tiny.en") {
        self.model = model
    }

    func prepare() async throws {
        guard whisperKit == nil else { return }
        AppLogger.transcription.info("Loading WhisperKit model: \(self.model)")
        let config = WhisperKitConfig(model: self.model, load: true)
        if let cached = cachedModelFolder() {
            AppLogger.transcription.debug("Using cached WhisperKit model folder")
            config.modelFolder = cached
        }
        let wk = try await WhisperKit(config)
        whisperKit = wk

        if let tokenizer = wk.tokenizer {
            let prompt = PromptProvider.resolve()
            let encoded = tokenizer.encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            promptTokens = encoded
            AppLogger.transcription.debug("Prompt encoded: \(encoded.count) tokens")
            if encoded.count > 224 {
                AppLogger.transcription.warning("Prompt exceeds 224 tokens and will be truncated by the decoder")
            }
        } else {
            AppLogger.transcription.warning("Tokenizer not available, skipping prompt conditioning")
        }

        AppLogger.transcription.info("WhisperKit ready")
    }

    func unload() {
        whisperKit = nil
        promptTokens = nil
    }

    private func cachedModelFolder() -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let path = docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(model)")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path.path)) ?? []
        guard contents.contains(where: { $0.hasSuffix(".mlmodelc") }) else { return nil }
        return path.path
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
        let text = results.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #if DEBUG
        if text.isEmpty {
            AppLogger.transcription.debug("Transcription result empty")
        } else {
            AppLogger.transcription.debug("Transcription result length=\(text.count)")
        }
        #endif
        return text
    }
}

enum TranscriptionError: Error {
    case engineNotReady
    case timeout
}
