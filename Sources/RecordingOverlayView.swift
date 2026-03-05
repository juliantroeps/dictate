import SwiftUI

struct RecordingOverlayView: View {
    let state: OverlayState

    var body: some View {
        Group {
            switch state.phase {
            case .idle:
                EmptyView()
            case .modelLoading:
                modelLoadingCapsule
            case .recording:
                recordingCapsule
            case .processing:
                processingCapsule
            case .error(let message):
                errorCapsule(message)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.15), value: state.phase == .idle)
    }

    private var modelLoadingCapsule: some View {
        HStack(spacing: 8) {
            ThreeDotsAnimation()
            Text("Loading model")
                .foregroundStyle(.white)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.opacity)
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
            ThreeDotsAnimation()
            Text("Processing")
                .foregroundStyle(.white)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.opacity)
    }

    private func errorCapsule(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .foregroundStyle(.white)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.opacity)
    }
}

struct ThreeDotsAnimation: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
                    .scaleEffect(animating ? 1.0 : 0.4)
                    .opacity(animating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .frame(height: 20)
        .onAppear { animating = true }
        .onDisappear { animating = false }
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
