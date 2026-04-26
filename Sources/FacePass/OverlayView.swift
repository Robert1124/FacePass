import FacePassCore
import SwiftUI

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var state: OverlayState

    init(state: OverlayState = OverlayState()) {
        self.state = state
    }
}

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @State private var isScanning = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 28, y: 14)

            VStack(spacing: 14) {
                phaseGlyph

                VStack(spacing: 5) {
                    Text(viewModel.state.phase.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)

                    Text(viewModel.state.phase.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 142)
                }
            }
            .padding(22)
        }
        .frame(width: 184, height: 184)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.state.phase.accessibilityLabel)
        .onAppear {
            updateScanningAnimation(for: viewModel.state.phase)
        }
        .onChange(of: viewModel.state.phase) { phase in
            updateScanningAnimation(for: phase)
        }
    }

    @ViewBuilder
    private var phaseGlyph: some View {
        switch viewModel.state.phase {
        case .scanning, .recognitionPreviewScanning:
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 4)

                Circle()
                    .trim(from: 0.06, to: 0.72)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(isScanning ? 360 : 0))

                Image(systemName: viewModel.state.phase.systemImageName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 68, height: 68)
        case .success, .recognitionPreviewRecognized:
            glyphCircle(color: .green)
        case .failure, .recognitionPreviewFailure:
            glyphCircle(color: .red)
        case .timeout:
            glyphCircle(color: .orange)
        case .idle:
            glyphCircle(color: .white.opacity(0.35))
        }
    }

    private func glyphCircle(color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
            Circle()
                .stroke(color.opacity(0.85), lineWidth: 3)
            Image(systemName: viewModel.state.phase.systemImageName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 68, height: 68)
    }

    private func updateScanningAnimation(for phase: OverlayPhase) {
        guard phase == .scanning || phase == .recognitionPreviewScanning else {
            isScanning = false
            return
        }

        isScanning = false
        withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
            isScanning = true
        }
    }
}
