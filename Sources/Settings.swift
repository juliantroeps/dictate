import CoreAudio
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

    var selectedInputDeviceID: AudioDeviceID? {
        didSet {
            if let id = selectedInputDeviceID {
                UserDefaults.standard.set(Int(id), forKey: "selectedInputDeviceID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedInputDeviceID")
            }
        }
    }

    var engineState: EngineState = .loading

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
                print("[dictate] Launch at login failed: \(error)")
            }
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        defaults.register(defaults: [
            "whisperModel": "openai_whisper-tiny.en",
            "noFocusBehavior": NoFocusBehavior.clipboard.rawValue,
            "muteSystemAudio": true,
        ])

        self.whisperModel = defaults.string(forKey: "whisperModel") ?? "openai_whisper-tiny.en"
        self.noFocusBehavior = NoFocusBehavior(rawValue: defaults.string(forKey: "noFocusBehavior") ?? "") ?? .clipboard
        self.muteSystemAudio = defaults.bool(forKey: "muteSystemAudio")
        if let savedID = defaults.object(forKey: "selectedInputDeviceID") as? Int {
            self.selectedInputDeviceID = AudioDeviceID(savedID)
        } else {
            self.selectedInputDeviceID = nil
        }
    }
}

enum EngineState {
    case loading
    case ready
    case failed
}

enum NoFocusBehavior: String, CaseIterable {
    case discard = "discard"
    case clipboard = "clipboard"

    var label: String {
        switch self {
        case .discard: "Discard silently"
        case .clipboard: "Copy to clipboard"
        }
    }
}
