import Testing

@testable import dictate

struct AudioDevicePolicyTests {
    private let policy = AudioDevicePolicy()

    @Test func manualSelectionOverridesCurrentDefault() {
        let action = policy.action(
            for: .init(
                selectedInputDeviceUID: "selected-device",
                resolvedSelectedInputID: 12,
                defaultInputID: 7,
                builtInInputID: 3,
                defaultInputIsBluetooth: true
            )
        )

        #expect(action == .applyManualSelection(12))
    }

    @Test func invalidSavedDeviceIsTreatedAsAutomatic() {
        let action = policy.action(
            for: .init(
                selectedInputDeviceUID: "missing-device",
                resolvedSelectedInputID: nil,
                defaultInputID: 8,
                builtInInputID: 3,
                defaultInputIsBluetooth: true
            )
        )

        #expect(action == .fallbackToBuiltIn(3))
    }

    @Test func bluetoothDefaultFallsBackOnlyWhenNoValidManualOverride() {
        let action = policy.action(
            for: .init(
                selectedInputDeviceUID: nil,
                resolvedSelectedInputID: nil,
                defaultInputID: 8,
                builtInInputID: 3,
                defaultInputIsBluetooth: true
            )
        )

        #expect(action == .fallbackToBuiltIn(3))
    }
}
