import AVFoundation
import AppKit

enum MicrophonePermission {
    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestInBackground() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            AppLogger.permissions.info("Microphone permission: \(granted)")
        }
    }

    /// requestAccess is a no-op once the user has answered, so a denied (or
    /// restricted) permission has to be changed in System Settings.
    static func requestOrOpenSettings() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            requestInBackground()
        } else {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
}
