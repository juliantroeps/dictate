import Foundation

enum EngineStatus: Equatable {
    case loading
    case ready
    case failed
}

@Observable
@MainActor
final class DictationRuntimeState {
    var phase: RecordingPhase = .idle
    var engineStatus: EngineStatus = .loading
    var audioLevel: Float = 0
    var keyDownTime: DispatchTime?
    var recordingStartTask: Task<Void, Never>?
    var transcriptionTask: Task<Void, Never>?
}
