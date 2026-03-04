import SwiftUI

struct SettingsView: View {
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    @State private var microphoneGranted = MicrophonePermission.isGranted

    var body: some View {
        VStack(spacing: 12) {
            Text("dictate")
                .font(.headline)

            Divider()

            if accessibilityGranted {
                Label("Accessibility enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Accessibility required", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    )
                }

                Text("Click +, then navigate to .build/debug/dictate and enable it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            if microphoneGranted {
                Label("Microphone enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Microphone required", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Button("Grant Permission") {
                    MicrophonePermission.requestInBackground()
                }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 240)
        .onAppear {
            accessibilityGranted = AccessibilityPermission.isGranted
            microphoneGranted = MicrophonePermission.isGranted
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            accessibilityGranted = AccessibilityPermission.isGranted
        }
    }
}
