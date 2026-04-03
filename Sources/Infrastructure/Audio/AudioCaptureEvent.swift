import Foundation

enum AudioCaptureEvent: Sendable, Equatable {
    case audioLevel(Float)
    case recordingInterrupted(samples: [Float])
    case inputConfigurationChanged(stable: Bool)
}
