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
        print("[dictate] Loading WhisperKit model: \(model)")
        let config = WhisperKitConfig(model: model, load: true)
        if let cached = cachedModelFolder() {
            print("[dictate] Using cached model at \(cached)")
            config.modelFolder = cached
        }
        let wk = try await WhisperKit(config)
        whisperKit = wk

        if let tokenizer = wk.tokenizer {
            let prompt = PromptProvider.resolve()
            let encoded = tokenizer.encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            promptTokens = encoded
            print("[dictate] Prompt encoded: \(encoded.count) tokens")
            if encoded.count > 224 {
                print("[dictate] WARNING: Prompt exceeds 224 tokens (\(encoded.count)), will be truncated by decoder")
            }
        } else {
            print("[dictate] WARNING: Tokenizer not available, skipping prompt conditioning")
        }

        print("[dictate] WhisperKit ready")
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
        return results.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum TranscriptionError: Error {
    case engineNotReady
    case timeout
}
