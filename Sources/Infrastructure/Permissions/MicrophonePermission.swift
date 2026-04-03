import AVFoundation

enum MicrophonePermission {
    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestInBackground() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            AppLogger.permissions.info("Microphone permission: \(granted)")
        }
    }
}
