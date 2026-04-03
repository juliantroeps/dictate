import CoreAudio

@testable import dictate

@MainActor
final class FakeAudioDeviceSettings: AudioDeviceSettingsProviding {
    var selectedInputDeviceUID: String?
}

final class FakeAudioDeviceController: AudioDeviceControlling, @unchecked Sendable {
    var defaultInputDeviceIDValue: AudioDeviceID?
    var defaultInputDeviceNameValue: String?
    var builtInInputDeviceIDValue: AudioDeviceID?
    var resolvedDeviceIDs: [String: AudioDeviceID] = [:]
    var deviceNames: [AudioDeviceID: String] = [:]
    var bluetoothDeviceIDs = Set<AudioDeviceID>()
    private(set) var setDefaultInputDeviceCalls: [AudioDeviceID] = []

    func defaultInputDeviceID() -> AudioDeviceID? {
        defaultInputDeviceIDValue
    }

    func defaultInputDeviceName() -> String? {
        defaultInputDeviceNameValue
    }

    func builtInInputDeviceID() -> AudioDeviceID? {
        builtInInputDeviceIDValue
    }

    func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        resolvedDeviceIDs[uid]
    }

    func deviceName(for deviceID: AudioDeviceID) -> String? {
        deviceNames[deviceID]
    }

    func isDeviceBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        bluetoothDeviceIDs.contains(deviceID)
    }

    func setDefaultInputDevice(_ deviceID: AudioDeviceID) {
        defaultInputDeviceIDValue = deviceID
        setDefaultInputDeviceCalls.append(deviceID)
    }
}
