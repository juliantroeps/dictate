import CoreAudio

enum SystemAudioController {
    private static var defaultOutputDevice: AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    static var defaultInputDeviceName: String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return deviceName(for: deviceID)
    }

    static var defaultOutputDeviceName: String? {
        let deviceID = defaultOutputDevice
        guard deviceID != 0 else { return nil }
        return deviceName(for: deviceID)
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr,
              let name = nameRef?.takeRetainedValue() else { return nil }
        return name as String
    }

    static func setMuted(_ muted: Bool) {
        let deviceID = defaultOutputDevice
        guard deviceID != 0 else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var mute: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mute)
        if status != noErr {
            print("[dictate] Failed to \(muted ? "mute" : "unmute") audio: \(status)")
        }
    }
}
