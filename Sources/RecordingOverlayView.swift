import SwiftUI

struct RecordingOverlayView: View {
    let state: OverlayState

    var body: some View {
        Group {
            switch state.phase {
            case .idle:
                EmptyView()
            case .recording:
                recordingCapsule
            case .processing:
                processingCapsule
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.phase == .idle)
    }

    private var recordingCapsule: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .medium))

            AudioLevelBars(level: state.audioLevel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.opacity)
    }

    private var processingCapsule: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text("Processing...")
                .foregroundStyle(.white)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.opacity)
    }
}

struct AudioLevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white)
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 20)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let baseHeight: CGFloat = 4
        let maxAdditional: CGFloat = 16
        let scale: [Float] = [0.7, 1.0, 0.7]
        let effective = CGFloat(level * scale[index])
        return baseHeight + maxAdditional * effective
    }
}
