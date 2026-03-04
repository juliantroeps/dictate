import SwiftUI

enum RecordingPhase: Equatable {
    case idle
    case recording
    case processing
    case error(String)
}

@Observable
@MainActor
final class OverlayState {
    var phase: RecordingPhase = .idle
    var audioLevel: Float = 0
}
