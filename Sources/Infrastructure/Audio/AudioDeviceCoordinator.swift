import CoreAudio
import Foundation
import Observation

protocol AudioDeviceControlling: AnyObject {
    func defaultInputDeviceID() -> AudioDeviceID?
    func defaultInputDeviceName() -> String?
    func builtInInputDeviceID() -> AudioDeviceID?
    func audioDeviceID(forUID uid: String) -> AudioDeviceID?
    func deviceName(for deviceID: AudioDeviceID) -> String?
    func isDeviceBluetooth(_ deviceID: AudioDeviceID) -> Bool
    func setDefaultInputDevice(_ deviceID: AudioDeviceID)
}

@MainActor
protocol AudioDeviceSettingsProviding: AnyObject {
    var selectedInputDeviceUID: String? { get }
}

extension Settings: AudioDeviceSettingsProviding {}

final class SystemAudioDeviceController: AudioDeviceControlling {
    func defaultInputDeviceID() -> AudioDeviceID? {
        SystemAudioController.defaultInputDeviceID
    }

    func defaultInputDeviceName() -> String? {
        SystemAudioController.defaultInputDeviceName
    }

    func builtInInputDeviceID() -> AudioDeviceID? {
        SystemAudioController.builtInInputDeviceID
    }

    func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        SystemAudioController.audioDeviceID(forUID: uid)
    }

    func deviceName(for deviceID: AudioDeviceID) -> String? {
        SystemAudioController.deviceName(for: deviceID)
    }

    func isDeviceBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        SystemAudioController.isDeviceBluetooth(deviceID)
    }

    func setDefaultInputDevice(_ deviceID: AudioDeviceID) {
        SystemAudioController.setDefaultInputDevice(deviceID)
    }
}

@MainActor
final class AudioDeviceCoordinator {
    private let settings: any AudioDeviceSettingsProviding
    private let overlay: any OverlayControlling
    private let policy = AudioDevicePolicy()
    private let audioDevices: any AudioDeviceControlling

    init(
        settings: any AudioDeviceSettingsProviding = Settings.shared,
        overlay: any OverlayControlling = OverlayController(),
        audioDevices: any AudioDeviceControlling = SystemAudioDeviceController()
    ) {
        self.settings = settings
        self.overlay = overlay
        self.audioDevices = audioDevices
    }

    func applyStartupSelectionIfNeeded() {
        guard let uid = settings.selectedInputDeviceUID,
              let deviceID = audioDevices.audioDeviceID(forUID: uid) else { return }
        audioDevices.setDefaultInputDevice(deviceID)
    }

    func observeSelectionChanges() {
        withObservationTracking {
            _ = settings.selectedInputDeviceUID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleSelectionChange()
                self.observeSelectionChanges()
            }
        }
    }

    func handleAudioCaptureEvent(_ event: AudioCaptureEvent) {
        switch event {
        case .inputConfigurationChanged(let stable):
            handleInputConfigurationChanged(stable: stable)
        case .audioLevel, .recordingInterrupted:
            break
        }
    }

    func handleInputConfigurationChanged(stable _: Bool = true) {
        guard let defaultID = audioDevices.defaultInputDeviceID() else { return }

        let selectedUID = settings.selectedInputDeviceUID
        let resolvedSelectedID = selectedUID.flatMap { audioDevices.audioDeviceID(forUID: $0) }

        switch policy.action(
            for: .init(
                selectedInputDeviceUID: selectedUID,
                resolvedSelectedInputID: resolvedSelectedID,
                defaultInputID: defaultID,
                builtInInputID: audioDevices.builtInInputDeviceID(),
                defaultInputIsBluetooth: audioDevices.isDeviceBluetooth(defaultID)
            )
        ) {
        case .applyManualSelection(let resolvedID):
            audioDevices.setDefaultInputDevice(resolvedID)
            AppLogger.device.info("Re-applied manual selection: \(selectedUID ?? "unknown")")
            return
        case .fallbackToBuiltIn(let builtInID):
            audioDevices.setDefaultInputDevice(builtInID)
            AppLogger.device.info("Auto-fallback: set system default to built-in mic")
            return
        case .keepCurrent:
            break
        }

        guard case .idle = overlay.state.phase else { return }

        let activeName: String
        if let resolvedSelectedID,
           let name = audioDevices.deviceName(for: resolvedSelectedID)
        {
            activeName = name
        } else {
            activeName = audioDevices.defaultInputDeviceName() ?? "Unknown mic"
        }
        overlay.showInfo(activeName, duration: 2.0)
    }

    private func handleSelectionChange() {
        if let uid = settings.selectedInputDeviceUID,
           let deviceID = audioDevices.audioDeviceID(forUID: uid)
        {
            audioDevices.setDefaultInputDevice(deviceID)
            return
        }

        handleInputConfigurationChanged()
    }
}
