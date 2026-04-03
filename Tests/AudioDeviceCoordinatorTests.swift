import Testing

@testable import dictate

struct AudioDeviceCoordinatorTests {
    @Test @MainActor
    func manualSelectionIsReappliedWhenSystemDefaultChanges() {
        let settings = FakeAudioDeviceSettings()
        settings.selectedInputDeviceUID = "selected-device"

        let controller = FakeAudioDeviceController()
        controller.defaultInputDeviceIDValue = 7
        controller.builtInInputDeviceIDValue = 3
        controller.resolvedDeviceIDs["selected-device"] = 12
        controller.deviceNames[12] = "Selected Mic"

        let overlay = FakeOverlayController()
        let coordinator = AudioDeviceCoordinator(
            settings: settings,
            overlay: overlay,
            audioDevices: controller
        )

        coordinator.handleInputConfigurationChanged()

        #expect(controller.setDefaultInputDeviceCalls == [12])
        #expect(overlay.shownInfos.isEmpty)
    }

    @Test @MainActor
    func bluetoothDefaultFallsBackToBuiltInWhenNoValidManualSelection() {
        let settings = FakeAudioDeviceSettings()
        settings.selectedInputDeviceUID = "missing-device"

        let controller = FakeAudioDeviceController()
        controller.defaultInputDeviceIDValue = 8
        controller.builtInInputDeviceIDValue = 3
        controller.bluetoothDeviceIDs.insert(8)

        let overlay = FakeOverlayController()
        let coordinator = AudioDeviceCoordinator(
            settings: settings,
            overlay: overlay,
            audioDevices: controller
        )

        coordinator.handleInputConfigurationChanged()

        #expect(controller.setDefaultInputDeviceCalls == [3])
        #expect(overlay.shownInfos.isEmpty)
    }

    @Test @MainActor
    func idleStateShowsActiveDeviceNameWithoutInterruptingRecording() {
        let settings = FakeAudioDeviceSettings()

        let controller = FakeAudioDeviceController()
        controller.defaultInputDeviceIDValue = 8
        controller.defaultInputDeviceNameValue = "Built-in Mic"

        let overlay = FakeOverlayController()
        let coordinator = AudioDeviceCoordinator(
            settings: settings,
            overlay: overlay,
            audioDevices: controller
        )

        coordinator.handleInputConfigurationChanged()

        #expect(controller.setDefaultInputDeviceCalls.isEmpty)
        #expect(overlay.shownInfos == ["Built-in Mic"])
    }
}
