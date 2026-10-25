import Foundation
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

    @Test @MainActor
    func fallbackGivesUpAfterRepeatedSwitchesInWindow() {
        let controller = FakeAudioDeviceController()
        controller.builtInInputDeviceIDValue = 3
        controller.bluetoothDeviceIDs.insert(8)

        var clock = Date(timeIntervalSince1970: 1_000)
        let coordinator = AudioDeviceCoordinator(
            settings: FakeAudioDeviceSettings(),
            overlay: FakeOverlayController(),
            audioDevices: controller,
            now: { clock }
        )

        // BT headset keeps grabbing the default back.
        var results: [Bool] = []
        for _ in 0..<5 {
            controller.defaultInputDeviceIDValue = 8
            results.append(coordinator.applyDevicePolicy())
            clock += 5
        }

        #expect(results == [true, true, true, false, false])
        #expect(controller.setDefaultInputDeviceCalls == [3, 3, 3])
    }

    @Test @MainActor
    func failedSwitchReportsNoChangeAndShowsCurrentDevice() {
        let controller = FakeAudioDeviceController()
        controller.defaultInputDeviceIDValue = 8
        controller.defaultInputDeviceNameValue = "AirPods"
        controller.builtInInputDeviceIDValue = 3
        controller.bluetoothDeviceIDs.insert(8)
        controller.setDefaultInputDeviceSucceeds = false

        let overlay = FakeOverlayController()
        let coordinator = AudioDeviceCoordinator(
            settings: FakeAudioDeviceSettings(),
            overlay: overlay,
            audioDevices: controller
        )

        #expect(!coordinator.applyDevicePolicy())
        coordinator.handleInputConfigurationChanged()
        #expect(overlay.shownInfos == ["AirPods"])
    }

    @Test @MainActor
    func builtInDefaultIsNotRewritten() {
        let controller = FakeAudioDeviceController()
        controller.defaultInputDeviceIDValue = 3
        controller.builtInInputDeviceIDValue = 3

        let coordinator = AudioDeviceCoordinator(
            settings: FakeAudioDeviceSettings(),
            overlay: FakeOverlayController(),
            audioDevices: controller
        )

        #expect(!coordinator.applyDevicePolicy())
        #expect(controller.setDefaultInputDeviceCalls.isEmpty)
    }
}
