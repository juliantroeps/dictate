import DictateCore
import Foundation
import ServiceManagement

@Observable
@MainActor
final class Settings {
    static let shared = Settings()

    var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }

    let minHoldDuration: Double = 0.4

    var noFocusBehavior: NoFocusBehavior {
        didSet { UserDefaults.standard.set(noFocusBehavior.rawValue, forKey: "noFocusBehavior") }
    }

    var muteSystemAudio: Bool {
        didSet { UserDefaults.standard.set(muteSystemAudio, forKey: "muteSystemAudio") }
    }

    /// Stable device UID for manual input selection (persists across BT reconnects)
    var selectedInputDeviceUID: String? {
        didSet {
            if let uid = selectedInputDeviceUID {
                UserDefaults.standard.set(uid, forKey: "selectedInputDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedInputDeviceUID")
            }
        }
    }

    /// UID of the output device we are actively holding muted (persists while a
    /// dictation-triggered mute is live, cleared on restore). Survives across
    /// relaunch so a crash mid-hold can be recovered even if the device's
    /// AudioDeviceID changed or the device disappeared.
    var activeMuteDeviceUID: String? {
        didSet {
            if let uid = activeMuteDeviceUID {
                UserDefaults.standard.set(uid, forKey: "activeMuteDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "activeMuteDeviceUID")
            }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                AppLogger.settings.error("Launch at login failed: \(error)")
            }
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        defaults.register(defaults: [
            "whisperModel": WhisperModels.defaultID,
            "noFocusBehavior": NoFocusBehavior.clipboard.rawValue,
            "muteSystemAudio": true,
        ])

        let storedModel = defaults.string(forKey: "whisperModel")
        let model = WhisperModels.resolve(stored: storedModel)
        if model != storedModel { defaults.set(model, forKey: "whisperModel") }
        self.whisperModel = model
        self.noFocusBehavior = NoFocusBehavior(rawValue: defaults.string(forKey: "noFocusBehavior") ?? "") ?? .clipboard
        self.muteSystemAudio = defaults.bool(forKey: "muteSystemAudio")
        self.selectedInputDeviceUID = defaults.string(forKey: "selectedInputDeviceUID")
        self.activeMuteDeviceUID = defaults.string(forKey: "activeMuteDeviceUID")
    }
}

enum WhisperModels {
    static let defaultID = "openai_whisper-small.en"

    /// Models removed from the picker; a stored selection falls back to the default.
    private static let retired: Set<String> = [
        "openai_whisper-medium.en",
        "distil-whisper_distil-large-v3_594MB",
    ]

    static func resolve(stored: String?) -> String {
        guard let stored, !retired.contains(stored) else { return defaultID }
        return stored
    }
}

enum NoFocusBehavior: String, CaseIterable {
    case discard
    case clipboard

    var label: String {
        switch self {
        case .discard: "Discard silently"
        case .clipboard: "Copy to clipboard"
        }
    }
}
