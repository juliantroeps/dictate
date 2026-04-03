import Foundation

enum AudioCaptureEvent: Sendable, Equatable {
    case audioLevel(Float)
    case recordingInterrupted
    case inputConfigurationChanged(stable: Bool)
}
