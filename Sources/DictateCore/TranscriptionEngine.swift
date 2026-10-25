import Foundation
@preconcurrency import WhisperKit

// MARK: - Protocol

public protocol TranscriptionEngine: Sendable {
    var name: String { get }
    var isReady: Bool { get }
    func prepare() async throws
    func transcribe(audioSamples: [Float]) async throws -> String
    func unload() async
}

// MARK: - Result

/// Transcription result plus the decode diagnostics the eval harness reports.
public struct TranscriptionDetail: Sendable {
    public let text: String
    /// Temperature each decoded segment settled on; any value above 0 means a fallback re-decode.
    public let segmentTemperatures: [Float]
    public let fallbackCount: Int
}

// MARK: - WhisperKitEngine

/// Actor-isolated so `prepare`/`transcribe`/`unload` can never race a model
/// swap - `whisperKit`/`promptTokens` are only ever touched on the actor's
/// own executor, whichever thread that happens to be.
public actor WhisperKitEngine: TranscriptionEngine {
    public let name = "WhisperKit"
    private var whisperKit: WhisperKit?
    private var promptTokens: [Int]?
    private let model: String
    private let prompt: @Sendable () -> String?
    private let adjustOptions: @Sendable (inout DecodingOptions) -> Void

    // isReady must be readable synchronously (EngineCoordinator.isReady is a
    // plain, non-async property), so it's tracked outside actor isolation
    // under a lock rather than derived from `whisperKit != nil`.
    private let readyLock = NSLock()
    nonisolated(unsafe) private var _isReady = false
    public nonisolated var isReady: Bool { readyLock.withLock { _isReady } }

    /// - Parameters:
    ///   - prompt: vocabulary prompt resolved on `prepare()`; nil disables prompt conditioning.
    ///   - adjustOptions: applied last to the app's decoding options (dictate-eval config overrides).
    public init(
        model: String = "openai_whisper-small.en",
        prompt: @escaping @Sendable () -> String? = { PromptProvider.resolve() },
        adjustOptions: @escaping @Sendable (inout DecodingOptions) -> Void = { _ in }
    ) {
        self.model = model
        self.prompt = prompt
        self.adjustOptions = adjustOptions
    }

    public func prepare() async throws {
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

        if let promptText = prompt() {
            if let tokenizer = wk.tokenizer {
                let encoded = tokenizer.encode(text: " " + promptText.trimmingCharacters(in: .whitespaces))
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                promptTokens = encoded
                AppLogger.transcription.debug("Prompt encoded: \(encoded.count) tokens")
                if encoded.count > 224 {
                    AppLogger.transcription.warning("Prompt exceeds 224 tokens and will be truncated by the decoder")
                }
            } else {
                AppLogger.transcription.warning("Tokenizer not available, skipping prompt conditioning")
            }
        } else {
            AppLogger.transcription.debug("Prompt conditioning disabled")
        }

        AppLogger.transcription.info("WhisperKit ready")
        readyLock.withLock { _isReady = true }
    }

    public func unload() async {
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

    public func transcribe(audioSamples: [Float]) async throws -> String {
        try await transcribeDetailed(audioSamples: audioSamples).text
    }

    /// App decoding options. dictate-eval builds on these so config C0 is exactly what the app runs.
    static func decodingOptions(promptTokens: [Int]?) -> DecodingOptions {
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
        return options
    }

    public func transcribeDetailed(audioSamples: [Float]) async throws -> TranscriptionDetail {
        guard let wk = whisperKit else {
            throw TranscriptionError.engineNotReady
        }

        var options = Self.decodingOptions(promptTokens: promptTokens)
        adjustOptions(&options)

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
        let first = results.first
        let text = first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #if DEBUG
            if text.isEmpty {
                AppLogger.transcription.debug("Transcription result empty")
            } else {
                AppLogger.transcription.debug("Transcription result length=\(text.count)")
            }
        #endif
        return TranscriptionDetail(
            text: text,
            segmentTemperatures: first?.segments.map(\.temperature) ?? [],
            fallbackCount: Int(first?.timings.totalDecodingFallbacks ?? 0))
    }
}

public enum TranscriptionError: Error {
    case engineNotReady
    case timeout
}
