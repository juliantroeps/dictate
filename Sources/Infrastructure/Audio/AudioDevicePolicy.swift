import CoreAudio

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
            let builtIn = context.builtInInputID
        {
            return .fallbackToBuiltIn(builtIn)
        }

        return .keepCurrent
    }
}
