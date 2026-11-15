import DictateCore
import Foundation
import WhisperKit

/// One `eval/configs/*.json` file. Example:
///
///     { "model": "openai_whisper-small.en", "prompt": true, "options": { "temperatureFallbackCount": 1 } }
///
/// - `name`: label in reports; defaults to the file name.
/// - `model`: WhisperKit model id (downloaded on first use if not cached).
/// - `prompt`: true (default) conditions on the app's default vocabulary prompt, false disables it.
///   `promptText` / `promptFile` replace the default text. `~/.dictate/prompt.txt` is never read
///   implicitly, so results do not depend on the machine; point `promptFile` at it to mimic your app.
/// - `model: "apple-dictation"` / `"apple-speech"` runs Apple's SpeechAnalyzer instead. `prompt` then toggles contextual
///   strings: `PromptProvider.defaultTerms`, or one per line from `termsFile`. `options` must be empty.
/// - `options`: overrides on top of the app's exact DecodingOptions (`WhisperKitEngine.decodingOptions`),
///   keyed by WhisperKit `DecodingOptions` property name. `null` clears an optional such as
///   `firstTokenLogProbThreshold`.
struct EvalConfig {
    let name: String
    let model: String
    let promptText: String?
    /// SpeechAnalyzer contextual strings; nil when the model is WhisperKit or `prompt` is false.
    var terms: [String]?
    let options: [String: Any]

    var isApple: Bool { SpeechAnalyzerEngine.isModelID(model) }
    var promptEnabled: Bool { isApple ? terms != nil : promptText != nil }

    enum LoadError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self {
            case .invalid(let message): message
            }
        }
    }

    private static let knownKeys: Set<String> = [
        "name", "model", "prompt", "promptText", "promptFile", "termsFile", "options",
    ]

    /// Every DecodingOptions property (optionals are absent from an encoded default, so list explicitly).
    private static let optionKeys: Set<String> = [
        "verbose", "task", "language", "temperature", "temperatureIncrementOnFallback",
        "temperatureFallbackCount", "sampleLength", "topK", "usePrefillPrompt", "usePrefillCache",
        "detectLanguage", "skipSpecialTokens", "withoutTimestamps", "wordTimestamps", "maxInitialTimestamp",
        "maxWindowSeek", "clipTimestamps", "windowClipTime", "prefixTokens", "suppressBlank", "supressTokens",
        "compressionRatioThreshold", "logProbThreshold", "firstTokenLogProbThreshold", "noSpeechThreshold",
        "concurrentWorkerCount", "chunkingStrategy",
    ]

    static func load(from url: URL) throws -> EvalConfig {
        let fallbackName = url.deletingPathExtension().lastPathComponent
        guard let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw LoadError.invalid("\(url.lastPathComponent): top level must be a JSON object")
        }
        if let unknown = Set(raw.keys).subtracting(knownKeys).sorted().first {
            throw LoadError.invalid("\(url.lastPathComponent): unknown key \"\(unknown)\"")
        }
        guard let model = raw["model"] as? String, !model.isEmpty else {
            throw LoadError.invalid("\(url.lastPathComponent): \"model\" is required")
        }

        var promptText: String?
        if (raw["prompt"] as? Bool) ?? true {
            if let text = raw["promptText"] as? String {
                promptText = text
            } else if let file = raw["promptFile"] as? String {
                let path = NSString(string: file).expandingTildeInPath
                promptText = try String(contentsOfFile: path, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                promptText = PromptProvider.defaultPrompt
            }
        }

        let options = raw["options"] as? [String: Any] ?? [:]
        if let unknown = Set(options.keys).subtracting(optionKeys).sorted().first {
            throw LoadError.invalid("\(url.lastPathComponent): unknown decoding option \"\(unknown)\"")
        }
        var config = EvalConfig(
            name: (raw["name"] as? String) ?? fallbackName, model: model, promptText: promptText, options: options)
        if config.isApple {
            guard options.isEmpty else {
                throw LoadError.invalid("\(url.lastPathComponent): \"options\" are WhisperKit-only")
            }
            if promptText != nil {
                if let file = raw["termsFile"] as? String {
                    let path = NSString(string: file).expandingTildeInPath
                    config.terms = PromptProvider.parseTerms(contentsOf: URL(fileURLWithPath: path))
                } else {
                    config.terms = PromptProvider.defaultTerms
                }
            }
            return config
        }
        // Fail on bad option values now rather than mid-run.
        do {
            _ = try Self.apply(config.options, to: DecodingOptions())
        } catch {
            throw LoadError.invalid("\(url.lastPathComponent): bad \"options\": \(error)")
        }
        return config
    }

    /// Round-trips through DecodingOptions' Codable so any property is overridable without a field list.
    static func apply(_ overrides: [String: Any], to base: DecodingOptions) throws -> DecodingOptions {
        guard !overrides.isEmpty else { return base }
        var merged = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any] ?? [:]
        for (key, value) in overrides {
            if value is NSNull {
                merged.removeValue(forKey: key)
            } else {
                merged[key] = value
            }
        }
        return try JSONDecoder().decode(
            DecodingOptions.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    /// Short description for reports.
    var summary: String {
        let optionsText =
            options.isEmpty
            ? "app defaults"
            : (try? String(
                data: JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]), encoding: .utf8))
                ?? "?"
        if isApple { return "model=\(model) terms=\(terms?.count ?? 0)" }
        return "model=\(model) prompt=\(promptEnabled ? "on" : "off") options=\(optionsText)"
    }

    /// Engine wired exactly like the app's, with this config's prompt and option overrides.
    func makeEngine() -> any EvalEngine {
        if isApple {
            let terms = terms ?? []
            return SpeechAnalyzerEngine(module: SpeechAnalyzerEngine.Module(rawValue: model)!, terms: { terms })
        }
        let promptText = promptText
        let optionsData = (try? JSONSerialization.data(withJSONObject: options)) ?? Data()
        return WhisperKitEngine(
            model: model,
            prompt: { promptText },
            adjustOptions: { decoding in
                let overrides = (try? JSONSerialization.jsonObject(with: optionsData)) as? [String: Any] ?? [:]
                if let applied = try? EvalConfig.apply(overrides, to: decoding) {
                    decoding = applied
                }
            })
    }
}

/// What the runner needs beyond `TranscriptionEngine`: decode diagnostics per clip.
protocol EvalEngine: TranscriptionEngine {
    func transcribeDetailed(audioSamples: [Float]) async throws -> TranscriptionDetail
}

extension WhisperKitEngine: EvalEngine {}

extension SpeechAnalyzerEngine: EvalEngine {
    func transcribeDetailed(audioSamples: [Float]) async throws -> TranscriptionDetail {
        TranscriptionDetail(text: try await transcribe(audioSamples: audioSamples))
    }
}
