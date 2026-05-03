import FacePassCompanionCore
import SwiftUI
import UIKit

@main
struct FacePassCompanionApp: App {
    @StateObject private var model: FacePassCompanionModel

    init() {
        let configuration = FacePassCompanionConfiguration(
            iphoneDisplayName: UIDevice.current.name
        )
        _model = StateObject(
            wrappedValue: FacePassCompanionModel(configuration: configuration)
        )
    }

    var body: some Scene {
        WindowGroup {
            FacePassCompanionRootView(model: model)
        }
    }
}

private struct FacePassCompanionRootView: View {
    @ObservedObject var model: FacePassCompanionModel

    var body: some View {
        Group {
            if let setupErrorMessage = model.setupErrorMessage {
                StartupErrorView(message: setupErrorMessage)
            } else if model.isPairingPresented || model.pairedMac == nil {
                PairingScanView(model: model)
            } else {
                PairedStatusView(model: model)
            }
        }
        .task {
            model.reloadPairedMac()
        }
    }
}

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Label("Setup Needed", systemImage: "key")
                    .font(.headline)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("FacePass")
        }
    }
}
