import Foundation
import Testing

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
}
