import Foundation
@preconcurrency import WhisperKit

// MARK: - Protocol

protocol TranscriptionEngine: Sendable {
    var name: String { get }
    var isReady: Bool { get }
    func prepare() async throws
    func transcribe(audioSamples: [Float]) async throws -> String
    func unload() async
}

// MARK: - WhisperKitEngine

/// Actor-isolated so `prepare`/`transcribe`/`unload` can never race a model
/// swap - `whisperKit`/`promptTokens` are only ever touched on the actor's
/// own executor, whichever thread that happens to be.
actor WhisperKitEngine: TranscriptionEngine {
    let name = "WhisperKit"
    private var whisperKit: WhisperKit?
    private var promptTokens: [Int]?
    private let model: String

    // isReady must be readable synchronously (EngineCoordinator.isReady is a
    // plain, non-async property), so it's tracked outside actor isolation
    // under a lock rather than derived from `whisperKit != nil`.
    private let readyLock = NSLock()
    nonisolated(unsafe) private var _isReady = false
    nonisolated var isReady: Bool { readyLock.withLock { _isReady } }

    init(model: String = "openai_whisper-small.en") {
        self.model = model
    }

    func prepare() async throws {
        guard whisperKit == nil else { return }
        AppLogger.transcription.info("Loading WhisperKit model: \(self.model)")
        // prewarm: true moves CoreML/ANE specialization into this background
        // load (already covered by the loading pill) instead of the first
        // transcribe call.
        let config = WhisperKitConfig(model: self.model, prewarm: true, load: true)
        let wk: WhisperKit
        if let cached = cachedModelFolder() {
            AppLogger.transcription.debug("Using cached WhisperKit model folder")
            config.modelFolder = cached
            do {
                wk = try await WhisperKit(config)
            } catch let cancellation as CancellationError {
                // Superseded load (model change / recover): do not start a download for it.
                throw cancellation
            } catch {
                // Corrupt/partial cache: retry once letting WhisperKit re-download.
                AppLogger.transcription.warning("Cached model load failed (\(error)); retrying with fresh download")
                config.modelFolder = nil
                wk = try await WhisperKit(config)
            }
        } else {
            wk = try await WhisperKit(config)
        }
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
        readyLock.withLock { _isReady = true }
    }

    func unload() async {
        whisperKit = nil
        promptTokens = nil
        readyLock.withLock { _isReady = false }
    }

    /// Compiled models WhisperKit needs to load; a folder missing any is a partial download.
    static let requiredModelBundles = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]

    private func cachedModelFolder() -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let path = docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(model)")
        return Self.isCompleteModelFolder(path.path) ? path.path : nil
    }

    static func isCompleteModelFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let contents = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
        return requiredModelBundles.allSatisfy(contents.contains)
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
        // Interactive-dictation latency/quality tradeoffs: timestamps are
        // decoded but never used by dictation, and the default fallback of
        // 5 full-window re-decodes on low confidence causes occasional
        // 3-5x slow dictations. Keep these conservative, not zero.
        options.withoutTimestamps = true
        options.temperatureFallbackCount = 1
        // WhisperKit's default windowClipTime (1.0s) makes its decode loop
        // (`seek < end - windowClipTime`) skip clips of 1s or less, returning "".
        // DictationCoordinator already gates empty/silent captures, so the extra
        // end-of-clip hallucination guard isn't worth dropping short dictations.
        options.windowClipTime = 0

        #if DEBUG
            let start = Date()
        #endif
        let results = try await wk.transcribe(audioArray: audioSamples, decodeOptions: options)
        #if DEBUG
            let elapsed = Date().timeIntervalSince(start)
            let audioSeconds = Double(audioSamples.count) / 16_000
            AppLogger.transcription.debug(
                String(format: "Transcribe wall=%.2fs audio=%.2fs", elapsed, audioSeconds))
        #endif
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
