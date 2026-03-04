import SwiftUI

enum RecordingPhase {
    case idle
    case recording
    case processing
}

@Observable
@MainActor
final class OverlayState {
    var phase: RecordingPhase = .idle
    var audioLevel: Float = 0
}
