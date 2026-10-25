import CoreAudio
import Foundation

enum AudioDeviceAction: Equatable {
    case applyManualSelection(AudioDeviceID)
    case fallbackToBuiltIn(AudioDeviceID)
    case keepCurrent
}

struct AudioDevicePolicy {
    struct Context {
        let selectedInputDeviceUID: String?
        let resolvedSelectedInputID: AudioDeviceID?
        let defaultInputID: AudioDeviceID?
        let builtInInputID: AudioDeviceID?
        let defaultInputIsBluetooth: Bool
    }

    func action(for context: Context) -> AudioDeviceAction {
        if let selected = context.resolvedSelectedInputID,
            let current = context.defaultInputID,
            selected != current
        {
            return .applyManualSelection(selected)
        }

        let hasValidManualSelection = context.selectedInputDeviceUID != nil && context.resolvedSelectedInputID != nil

        if !hasValidManualSelection,
            context.defaultInputIsBluetooth,
            let builtIn = context.builtInInputID,
            context.defaultInputID != builtIn
        {
            return .fallbackToBuiltIn(builtIn)
        }

        return .keepCurrent
    }
}

/// Bounds how often we rewrite the system default input. Each write triggers another
/// device change, so a device that keeps grabbing the default (BT reconnect loops)
/// would otherwise make us fight it forever. Debounces, then gives up for the window.
struct DeviceSwitchRateLimiter {
    var minInterval: TimeInterval = 2
    var window: TimeInterval = 30
    var maxSwitches = 3
    private var switches: [Date] = []

    /// Returns true (and records the switch) if a switch is allowed at `now`.
    mutating func allow(at now: Date) -> Bool {
        switches.removeAll { now.timeIntervalSince($0) >= window }
        if let last = switches.last, now.timeIntervalSince(last) < minInterval { return false }
        guard switches.count < maxSwitches else { return false }
        switches.append(now)
        return true
    }
}
