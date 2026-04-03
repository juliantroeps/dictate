import Combine
import CoreAudio
import Foundation
import Observation

@MainActor
final class SettingsRefreshController: ObservableObject {
    @Published private(set) var inputDevices: [(id: AudioDeviceID, name: String)] = []
    @Published private(set) var outputDeviceName = ""
    @Published private(set) var microphoneGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var selectedInputDeviceID: AudioDeviceID?
    @Published private(set) var savedInputDeviceMissing = false

    private let settings: Settings
    private var refreshTimer: Timer?
    private var isStarted = false

    init(settings: Settings = .shared) {
        self.settings = settings
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refresh()
        observeSelectionChanges()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        isStarted = false
    }

    func setSelectedInputDeviceID(_ deviceID: AudioDeviceID?) {
        if let deviceID {
            settings.selectedInputDeviceUID = SystemAudioController.deviceUID(for: deviceID)
        } else {
            settings.selectedInputDeviceUID = nil
        }
        refreshSelectionState()
    }

    private func refresh() {
        accessibilityGranted = AccessibilityPermission.isGranted
        microphoneGranted = MicrophonePermission.isGranted
        inputDevices = SystemAudioController.allInputDevices
        outputDeviceName = SystemAudioController.defaultOutputDeviceName ?? ""
        refreshSelectionState()
    }

    private func refreshSelectionState() {
        guard let selectedUID = settings.selectedInputDeviceUID else {
            selectedInputDeviceID = nil
            savedInputDeviceMissing = false
            return
        }

        let resolvedID = SystemAudioController.audioDeviceID(forUID: selectedUID)
        selectedInputDeviceID = resolvedID
        savedInputDeviceMissing = resolvedID == nil
    }

    private func observeSelectionChanges() {
        withObservationTracking {
            _ = settings.selectedInputDeviceUID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.refreshSelectionState()
                self.observeSelectionChanges()
            }
        }
    }
}
