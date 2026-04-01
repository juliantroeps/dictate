import CoreAudio
import SwiftUI

struct SettingsView: View {
    private let settings = Settings.shared
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    @State private var microphoneGranted = MicrophonePermission.isGranted
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []
    @State private var outputDeviceName = SystemAudioController.defaultOutputDeviceName ?? ""

    private let models: [(id: String, label: String, memory: String)] = [
        ("openai_whisper-tiny.en", "tiny.en", "~75 MB"),
        ("openai_whisper-base.en", "base.en", "~150 MB"),
        ("openai_whisper-small.en", "small.en", "~500 MB"),
        ("openai_whisper-medium.en", "medium.en", "~1.5 GB"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("dictate").font(.headline)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Dev")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // -- Transcription --
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription").font(.subheadline).foregroundStyle(.secondary)

                Picker("Model", selection: Bindable(settings).whisperModel) {
                    ForEach(models, id: \.id) { model in
                        Text("\(model.label)  \(model.memory)").tag(model.id)
                    }
                }

                switch settings.engineState {
                case .loading:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.caption).foregroundStyle(.secondary)
                    }
                case .ready:
                    Label("Model ready", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Label("Failed to load model", systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundColor(.red)
                }
            }

            Divider()

            // -- Behavior --
            VStack(alignment: .leading, spacing: 6) {
                Text("Behavior").font(.subheadline).foregroundStyle(.secondary)

                Picker("No text field", selection: Bindable(settings).noFocusBehavior) {
                    ForEach(NoFocusBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }

                Toggle("Mute system audio while recording", isOn: Bindable(settings).muteSystemAudio)

                Picker("Input", selection: Binding<AudioDeviceID?>(
                    get: {
                        // Resolve UID to current device ID for picker display
                        guard let uid = settings.selectedInputDeviceUID else { return nil }
                        return SystemAudioController.audioDeviceID(forUID: uid)
                    },
                    set: { (newID: AudioDeviceID?) in
                        // Store stable UID when user selects a device
                        if let id = newID {
                            settings.selectedInputDeviceUID = SystemAudioController.deviceUID(for: id)
                        } else {
                            settings.selectedInputDeviceUID = nil
                        }
                    }
                )) {
                    Text("Automatic").tag(AudioDeviceID?.none)
                    ForEach(inputDevices, id: \.id) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }

                // Warn when saved device is disconnected - fallback is active
                if let savedUID = settings.selectedInputDeviceUID,
                   SystemAudioController.audioDeviceID(forUID: savedUID) == nil {
                    Text("Saved device not connected - using fallback")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !outputDeviceName.isEmpty {
                    HStack {
                        Text("Output").foregroundStyle(.secondary)
                        Spacer()
                        Text(outputDeviceName).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }

            Divider()

            // -- General --
            VStack(alignment: .leading, spacing: 6) {
                Text("General").font(.subheadline).foregroundStyle(.secondary)

                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // -- Permissions --
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions").font(.subheadline).foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    if accessibilityGranted {
                        Label("Accessibility", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        } label: {
                            Label("Accessibility", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                    }

                    if microphoneGranted {
                        Label("Microphone", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button {
                            MicrophonePermission.requestInBackground()
                        } label: {
                            Label("Microphone", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 280)
        .onAppear {
            microphoneGranted = MicrophonePermission.isGranted
            inputDevices = SystemAudioController.allInputDevices
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            accessibilityGranted = AccessibilityPermission.isGranted
            microphoneGranted = MicrophonePermission.isGranted
            inputDevices = SystemAudioController.allInputDevices
            outputDeviceName = SystemAudioController.defaultOutputDeviceName ?? ""
        }
    }
}
