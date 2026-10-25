import Testing

@testable import dictate

struct WhisperModelsTests {
    @Test func retiredModelsFallBackToDefault() {
        for id in ["openai_whisper-medium.en", "distil-whisper_distil-large-v3_594MB"] {
            #expect(WhisperModels.resolve(stored: id) == WhisperModels.defaultID, "\(id)")
        }
    }

    @Test func pickerModelsAreKept() {
        for id in [
            "openai_whisper-tiny.en", "openai_whisper-small.en",
            "openai_whisper-large-v3-v20240930_turbo_632MB",
        ] {
            #expect(WhisperModels.resolve(stored: id) == id, "\(id)")
        }
    }

    @Test func missingSelectionUsesDefault() {
        #expect(WhisperModels.resolve(stored: nil) == WhisperModels.defaultID)
    }
}
