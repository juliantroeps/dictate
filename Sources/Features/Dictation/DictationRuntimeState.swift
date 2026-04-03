import Foundation

@Observable
@MainActor
final class DictationRuntimeState {
    var phase: RecordingPhase = .idle
    var audioLevel: Float = 0
    var keyDownTime: DispatchTime?
    var recordingStartTask: Task<Void, Never>?
    var transcriptionTask: Task<Void, Never>?
}
