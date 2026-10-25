import Foundation
import Testing

@testable import DictateCore
@testable import dictate

struct PromptProviderTests {
    @Test func customPromptFileOverridesDefaultPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let promptURL = directory.appendingPathComponent("prompt.txt")
        try "  custom prompt text  \n".write(to: promptURL, atomically: true, encoding: .utf8)

        #expect(PromptProvider.resolve(from: promptURL) == "custom prompt text")
    }

    @Test func emptyPromptFileFallsBackToDefaultPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let promptURL = directory.appendingPathComponent("prompt.txt")
        try "".write(to: promptURL, atomically: true, encoding: .utf8)

        #expect(PromptProvider.resolve(from: promptURL) == PromptProvider.defaultPrompt)
    }

    @Test func promptIsSkippedForTurboFamily() {
        let turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
        #expect(!PromptProvider.supportsPrompt(model: turbo))
        #expect(PromptProvider.resolve(forModel: turbo) == nil)
    }

    @Test func promptIsKeptForOtherPickerModels() {
        let models = ["openai_whisper-tiny.en", "openai_whisper-small.en"]
        for model in models {
            #expect(PromptProvider.supportsPrompt(model: model), "\(model)")
            #expect(PromptProvider.resolve(forModel: model) != nil, "\(model)")
        }
    }

    @Test func defaultPromptFixedAndTrimmed() {
        #expect(!PromptProvider.defaultPrompt.contains("MonogDB"))
        #expect(PromptProvider.defaultPrompt.contains("MongoDB"))
        #expect(PromptProvider.defaultPrompt.count < 300)
    }
}
