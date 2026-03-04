import SwiftUI

struct SettingsView: View {
    private let settings = Settings.shared
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    @State private var microphoneGranted = MicrophonePermission.isGranted

    private let models: [(id: String, label: String, memory: String)] = [
        ("openai_whisper-tiny.en", "tiny.en", "~75 MB"),
        ("openai_whisper-base.en", "base.en", "~150 MB"),
        ("openai_whisper-small.en", "small.en", "~500 MB"),
        ("openai_whisper-medium.en", "medium.en", "~1.5 GB"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            Text("dictate").font(.headline)

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
            }

            Divider()

            // -- General --
            VStack(alignment: .leading, spacing: 6) {
                Text("General").font(.subheadline).foregroundStyle(.secondary)

                Toggle("Launch at login", isOn: .constant(false))
                    .disabled(true)
                    .help("Available after installing as app")
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
        .onAppear { microphoneGranted = MicrophonePermission.isGranted }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            accessibilityGranted = AccessibilityPermission.isGranted
        }
    }
}
