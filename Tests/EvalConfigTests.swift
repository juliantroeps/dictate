import Foundation
import Testing
import WhisperKit

@testable import DictateCore
@testable import dictate_eval

struct EvalConfigTests {
    private func load(_ json: String, file: String = "cfg.json") throws -> EvalConfig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(file)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return try EvalConfig.load(from: url)
    }

    @Test func defaultsToAppPromptAndFileName() throws {
        let config = try load(#"{ "model": "m" }"#, file: "C9.json")
        #expect(config.name == "C9")
        #expect(config.model == "m")
        #expect(config.promptText == PromptProvider.defaultPrompt)
        #expect(config.options.isEmpty)
    }

    @Test func promptCanBeDisabledOrReplaced() throws {
        #expect(try load(#"{ "model": "m", "prompt": false }"#).promptText == nil)
        #expect(try load(#"{ "model": "m", "promptText": "Foo, Bar." }"#).promptText == "Foo, Bar.")
    }

    @Test func rejectsUnknownKeysAndMissingModel() {
        #expect(throws: EvalConfig.LoadError.self) { try load(#"{ "model": "m", "promt": true }"#) }
        #expect(throws: EvalConfig.LoadError.self) { try load(#"{ "model": "m", "options": { "windowClip": 0 } }"#) }
        #expect(throws: EvalConfig.LoadError.self) { try load(#"{ "prompt": true }"#) }
    }

    @Test func rejectsBadOptionValues() {
        #expect(throws: EvalConfig.LoadError.self) {
            try load(#"{ "model": "m", "options": { "temperatureFallbackCount": "many" } }"#)
        }
    }

    @Test func optionsOverrideAppDefaultsAndNullClearsOptionals() throws {
        let config = try load(
            #"""
            { "model": "m", "options": { "windowClipTime": 1.0, "temperatureFallbackCount": 5,
              "firstTokenLogProbThreshold": null, "withoutTimestamps": false } }
            """#)
        let base = WhisperKitEngine.decodingOptions(promptTokens: [1, 2, 3])
        #expect(base.windowClipTime == 0)
        #expect(base.firstTokenLogProbThreshold == -1.5)

        let applied = try EvalConfig.apply(config.options, to: base)
        #expect(applied.windowClipTime == 1.0)
        #expect(applied.temperatureFallbackCount == 5)
        #expect(applied.firstTokenLogProbThreshold == nil)
        #expect(!applied.withoutTimestamps)
        // Untouched fields keep the app's values, including the prompt.
        #expect(applied.promptTokens == [1, 2, 3])
        #expect(applied.usePrefillPrompt)
    }
}
