import AVFoundation

enum MicrophonePermission {
    static var isGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
