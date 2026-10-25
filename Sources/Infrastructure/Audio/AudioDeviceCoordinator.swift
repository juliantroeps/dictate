import CoreAudio
import DictateCore
import Foundation
import Observation

protocol AudioDeviceControlling: AnyObject {
    func defaultInputDeviceID() -> AudioDeviceID?
    func defaultInputDeviceName() -> String?
    func builtInInputDeviceID() -> AudioDeviceID?
    func audioDeviceID(forUID uid: String) -> AudioDeviceID?
    func deviceName(for deviceID: AudioDeviceID) -> String?
    func isDeviceBluetooth(_ deviceID: AudioDeviceID) -> Bool
    func transportType(for deviceID: AudioDeviceID) -> UInt32
    @discardableResult func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool
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

    func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        SystemAudioController.transportType(for: deviceID)
    }

    @discardableResult func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        SystemAudioController.setDefaultInputDevice(deviceID)
    }
}

@MainActor
final class AudioDeviceCoordinator {
    private let settings: any AudioDeviceSettingsProviding
    private let overlay: any OverlayControlling
    private let policy = AudioDevicePolicy()
    private let audioDevices: any AudioDeviceControlling
    private let now: () -> Date
    private var rateLimiter = DeviceSwitchRateLimiter()

    init(
        settings: any AudioDeviceSettingsProviding = Settings.shared,
        overlay: any OverlayControlling = OverlayController(),
        audioDevices: any AudioDeviceControlling = SystemAudioDeviceController(),
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.overlay = overlay
        self.audioDevices = audioDevices
        self.now = now
    }

    func applyStartupSelectionIfNeeded() {
        guard let uid = settings.selectedInputDeviceUID,
            let deviceID = audioDevices.audioDeviceID(forUID: uid)
        else { return }
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

    func handleInputConfigurationChanged() {
        guard !applyDevicePolicy() else { return }
        showActiveDeviceIfIdle()
    }

    /// Applies the manual selection / BT->built-in fallback. Returns true only if the
    /// system default was actually changed: another config change follows, so callers
    /// can skip work (like restarting capture) on the device we just switched away from.
    func applyDevicePolicy() -> Bool {
        guard let defaultID = audioDevices.defaultInputDeviceID() else { return false }

        let selectedUID = settings.selectedInputDeviceUID
        let resolvedSelectedID = selectedUID.flatMap { audioDevices.audioDeviceID(forUID: $0) }

        let action = policy.action(
            for: .init(
                selectedInputDeviceUID: selectedUID,
                resolvedSelectedInputID: resolvedSelectedID,
                defaultInputID: defaultID,
                builtInInputID: audioDevices.builtInInputDeviceID(),
                defaultInputIsBluetooth: audioDevices.isDeviceBluetooth(defaultID)
            )
        )
        let targetID: AudioDeviceID
        let label: String
        switch action {
        case .applyManualSelection(let id):
            (targetID, label) = (id, "Re-apply manual selection")
        case .fallbackToBuiltIn(let id):
            (targetID, label) = (id, "Auto-fallback to built-in")
        case .keepCurrent:
            return false
        }

        let from = describe(defaultID)
        let to = describe(targetID)
        guard rateLimiter.allow(at: now()) else {
            AppLogger.device.info("\(label) skipped (rate limited): \(from) -> \(to)")
            return false
        }
        guard audioDevices.setDefaultInputDevice(targetID) else {
            AppLogger.device.error("\(label) failed: \(from) -> \(to)")
            return false
        }
        AppLogger.device.info("\(label): \(from) -> \(to)")
        return true
    }

    func showActiveDeviceIfIdle() {
        guard case .idle = overlay.state.phase else { return }

        let resolvedSelectedID = settings.selectedInputDeviceUID.flatMap { audioDevices.audioDeviceID(forUID: $0) }
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

    /// "Name [btle]" - device name plus CoreAudio transport type fourcc, for logs.
    private func describe(_ deviceID: AudioDeviceID) -> String {
        let name = audioDevices.deviceName(for: deviceID) ?? "id \(deviceID)"
        let transport = audioDevices.transportType(for: deviceID).bigEndian
        let code = withUnsafeBytes(of: transport) { String(bytes: $0, encoding: .ascii) } ?? "?"
        return "\(name) [\(code.trimmingCharacters(in: .controlCharacters))]"
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
