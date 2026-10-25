import Foundation
import Testing

@testable import DictateCore
@testable import dictate

struct WhisperKitEngineTests {
    private func makeFolder(containing bundles: [String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for bundle in bundles {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(bundle), withIntermediateDirectories: true)
        }
        return dir.path
    }

    @Test func completeFolderIsAccepted() throws {
        let path = try makeFolder(containing: WhisperKitEngine.requiredModelBundles)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(WhisperKitEngine.isCompleteModelFolder(path))
    }

    @Test func partialFolderIsRejected() throws {
        let path = try makeFolder(containing: ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(!WhisperKitEngine.isCompleteModelFolder(path))
    }

    @Test func missingFolderIsRejected() {
        #expect(!WhisperKitEngine.isCompleteModelFolder("/nonexistent/\(UUID().uuidString)"))
    }
}
