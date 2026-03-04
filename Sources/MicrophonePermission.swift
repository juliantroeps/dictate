import AVFoundation

enum MicrophonePermission {
    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestInBackground() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            print("[dikt] Microphone permission: \(granted)")
        }
    }
}
