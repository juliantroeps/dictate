import Foundation
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

    @Test func builtInDefaultIsKeptEvenIfReportedBluetooth() {
        let action = policy.action(
            for: .init(
                selectedInputDeviceUID: nil,
                resolvedSelectedInputID: nil,
                defaultInputID: 3,
                builtInInputID: 3,
                defaultInputIsBluetooth: true
            )
        )

        #expect(action == .keepCurrent)
    }
}

struct DeviceSwitchRateLimiterTests {
    /// Runs allow(at:) for each offset (seconds) from a fixed start, in order.
    private func run(_ offsets: [TimeInterval]) -> [Bool] {
        var limiter = DeviceSwitchRateLimiter()
        let t0 = Date(timeIntervalSince1970: 1_000)
        return offsets.map { limiter.allow(at: t0 + $0) }
    }

    @Test func debouncesSwitchesWithinMinInterval() {
        #expect(run([0, 1, 2]) == [true, false, true])
    }

    @Test func givesUpAfterMaxSwitchesInWindow() {
        #expect(run([0, 5, 10, 15, 29]) == [true, true, true, false, false])
    }

    @Test func recoversOnceWindowPasses() {
        // First switch (t0) ages out at t0 + 30.
        #expect(run([0, 5, 10, 20, 30]) == [true, true, true, false, true])
    }

    @Test func deniedAttemptsDoNotCount() {
        #expect(run([0, 0.5, 1, 2, 4]) == [true, false, false, true, true])
    }
}
