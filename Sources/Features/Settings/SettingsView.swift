import CoreAudio
import SwiftUI

struct SettingsView: View {
    struct ModelOption {
        let id: String
        let label: String
        let memory: String
    }

    private let settings = Settings.shared
    private let engineRuntimeState: DictationRuntimeState
    @StateObject private var refreshController = SettingsRefreshController()

    private let models: [ModelOption] = [
        .init(id: "openai_whisper-tiny.en", label: "tiny.en", memory: "~75 MB"),
        .init(id: "openai_whisper-small.en", label: "small.en", memory: "~500 MB"),
        .init(id: "openai_whisper-medium.en", label: "medium.en", memory: "~1.5 GB"),
    ]

    init(engineRuntimeState: DictationRuntimeState) {
        self.engineRuntimeState = engineRuntimeState
    }

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

                switch engineRuntimeState.engineStatus {
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
                        refreshController.selectedInputDeviceID
                    },
                    set: { (newID: AudioDeviceID?) in
                        refreshController.setSelectedInputDeviceID(newID)
                    }
                )) {
                    Text("Automatic").tag(AudioDeviceID?.none)
                    ForEach(refreshController.inputDevices, id: \.id) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }

                if refreshController.savedInputDeviceMissing {
                    Text("Saved device not connected - using fallback")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !refreshController.outputDeviceName.isEmpty {
                    HStack {
                        Text("Output").foregroundStyle(.secondary)
                        Spacer()
                        Text(refreshController.outputDeviceName).foregroundStyle(.secondary)
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
                    if refreshController.accessibilityGranted {
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

                    if refreshController.microphoneGranted {
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
            refreshController.start()
        }
        .onDisappear {
            refreshController.stop()
        }
    }
}
