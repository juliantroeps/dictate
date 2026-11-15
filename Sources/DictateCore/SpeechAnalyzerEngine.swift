@preconcurrency import AVFoundation
import Foundation
import Speech

/// Apple's on-device `SpeechAnalyzer` (macOS 26+). Eval-only (C8a-d): 3-5x small.en's WER on dev dictation. The model is OS-managed (downloaded once via
/// `AssetInventory`, shared across apps); vocabulary hints go in as `AnalysisContext.contextualStrings`.
/// A fresh analyzer per clip: `finalizeAndFinish` ends a session.
public actor SpeechAnalyzerEngine: TranscriptionEngine {
    public enum Module: String, Sendable, CaseIterable {
        /// `DictationTranscriber`: keyboard-dictation model, documented to honor contextual strings.
        case dictation = "apple-dictation"
        /// `SpeechTranscriber`: newer long-form model; contextual strings reportedly ignored.
        case speech = "apple-speech"
    }

    public static func isModelID(_ id: String) -> Bool { Module(rawValue: id) != nil }

    public let name = "SpeechAnalyzer"
    private let module: Module
    private let requestedLocale: Locale
    private let terms: @Sendable () -> [String]
    private var locale: Locale?
    private var analyzerFormat: AVAudioFormat?
    private var contextualStrings: [String] = []

    private let readyLock = NSLock()
    nonisolated(unsafe) private var _isReady = false
    public nonisolated var isReady: Bool { readyLock.withLock { _isReady } }

    /// - Parameter terms: contextual strings resolved on `prepare()`; empty disables biasing.
    public init(
        module: Module = .dictation,
        locale: Locale = Locale(identifier: "en_US"),
        terms: @escaping @Sendable () -> [String]
    ) {
        self.module = module
        self.requestedLocale = locale
        self.terms = terms
    }

    /// The module plus its results as plain strings. With no volatile reporting every result is
    /// final, but `isFinal` still reads false (finalization time stays 0), so it is not filtered on.
    private func makeTranscriber(locale: Locale) -> (any SpeechModule, AsyncThrowingStream<String, Error>) {
        switch module {
        case .dictation:
            let transcriber = DictationTranscriber(
                locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                reportingOptions: [], attributeOptions: [])
            return (transcriber, Self.texts(transcriber.results) { String($0.text.characters) })
        case .speech:
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            return (transcriber, Self.texts(transcriber.results) { String($0.text.characters) })
        }
    }

    private static func texts<S: AsyncSequence & Sendable>(
        _ results: S, _ text: @escaping @Sendable (S.Element) -> String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results { continuation.yield(text(result)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func supportedLocale(for module: Module, equivalentTo locale: Locale) async -> Locale? {
        switch module {
        case .dictation: await DictationTranscriber.supportedLocale(equivalentTo: locale)
        case .speech: await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }
    }

    public func prepare() async throws {
        guard locale == nil else { return }
        guard let supported = await Self.supportedLocale(for: module, equivalentTo: requestedLocale) else {
            throw SpeechAnalyzerEngineError.unsupportedLocale(requestedLocale.identifier)
        }
        let (transcriber, _) = makeTranscriber(locale: supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            AppLogger.transcription.info("Downloading Apple speech assets for \(supported.identifier)")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechAnalyzerEngineError.noAudioFormat
        }
        contextualStrings = terms()
        analyzerFormat = format
        locale = supported
        AppLogger.transcription.info(
            "SpeechAnalyzer ready (\(module.rawValue), \(supported.identifier), \(contextualStrings.count) terms)")
        readyLock.withLock { _isReady = true }
    }

    public func unload() async {
        locale = nil
        analyzerFormat = nil
        readyLock.withLock { _isReady = false }
    }

    /// Trailing silence so the endpointer commits the last word; without it the final word is dropped.
    static let trailingSilence = [Float](repeating: 0, count: 16_000)

    public func transcribe(audioSamples: [Float]) async throws -> String {
        guard let locale, let analyzerFormat else { throw TranscriptionError.engineNotReady }
        guard !audioSamples.isEmpty else { return "" }

        let (transcriber, results) = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }

        let collector = Task {
            var parts: [String] = []
            for try await text in results { parts.append(text) }
            return parts
        }

        let buffer = try Self.convert(audioSamples + Self.trailingSilence, to: analyzerFormat)
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        do {
            if let lastSample = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 16 kHz mono Float32 (the app's capture format) -> whatever the analyzer wants (Int16 today).
    static func convert(_ samples: [Float], to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw SpeechAnalyzerEngineError.conversionFailed }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        if format == sourceFormat { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw SpeechAnalyzerEngineError.conversionFailed
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / sourceFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw SpeechAnalyzerEngineError.conversionFailed
        }
        nonisolated(unsafe) var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error { throw conversionError ?? SpeechAnalyzerEngineError.conversionFailed }
        return output
    }
}

public enum SpeechAnalyzerEngineError: Error {
    case unsupportedLocale(String)
    case noAudioFormat
    case conversionFailed
}
