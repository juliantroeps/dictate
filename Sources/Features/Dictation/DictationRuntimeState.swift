import CoreAudio
import Foundation

enum EngineStatus: Equatable {
    case loading
    case ready
    case failed
}

/// Captures the mute context at key-down so it can be precisely restored at key-up.
struct ActiveMute {
    let deviceID: AudioDeviceID
    let priorMuted: Bool
}

@Observable
@MainActor
final class DictationRuntimeState {
    var engineStatus: EngineStatus = .loading
    var audioLevel: Float = 0
    var keyDownTime: DispatchTime?
    var recordingStartTask: Task<Void, Never>?
    var transcriptionTask: Task<Void, Never>?
    /// Monotonic token; only the task whose captured generation still matches
    /// may mutate phase/overlay or nil out the task handle. Guards against a
    /// late-resuming cancelled transcription stomping a newer session's state.
    var transcriptionGeneration: Int = 0
    /// Set when we actually mutied on key-down; cleared after restore.
    var activeMute: ActiveMute?
    /// True while the Fn key is physically held, independent of keyDownTime
    /// (which is cleared on device-change interruption). Used to re-arm capture
    /// after an interruption while the user keeps holding.
    var keyHeld = false
    /// Audio captured before the engine was ready. Flushed via onReady when the
    /// engine finishes loading. A newer key-up overwrites an older pending buffer
    /// (newest session wins, matching the generation-guard semantics).
    var pendingSamples: [Float]?
}
