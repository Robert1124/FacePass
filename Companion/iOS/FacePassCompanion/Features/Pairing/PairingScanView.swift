import FacePassCompanionCore
import SwiftUI

struct PairingScanView: View {
    @ObservedObject var model: FacePassCompanionModel

    @State private var manualPayload = ""
    @State private var status = "Scan the FacePass pairing QR code on your Mac."
    @State private var cameraState: QRCodeScannerAuthorizationState = .checking
    @State private var decodedPayload: PairingQRCodePayload?
    @State private var isPairing = false
    @State private var lastScannedCode: String?

    private let decoder = PairingPayloadDecoder()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        scannerPanel

                        Text(status)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)

                        if let decodedPayload {
                            decodedPayloadView(decodedPayload)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    TextEditor(text: $manualPayload)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 130)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task {
                            await submit(manualPayload)
                        }
                    } label: {
                        Label("Pair from Pasted JSON", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(isPairing || manualPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Manual Pairing JSON")
                } footer: {
                    Text("Use this field for simulator and development builds when the camera is unavailable.")
                }
            }
            .navigationTitle("Pair Mac")
            .toolbar {
                if model.pairedMac != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Cancel") {
                            model.isPairingPresented = false
                        }
                    }
                }
            }
        }
    }

    private var scannerPanel: some View {
        ZStack {
            QRCodeScannerView(
                authorizationState: $cameraState,
                onCodeScanned: { code in
                    Task {
                        await submitScannedCode(code)
                    }
                }
            )

            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.78), lineWidth: 2)
                .padding(34)
                .allowsHitTesting(false)

            scannerOverlayMessage
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var scannerOverlayMessage: some View {
        switch cameraState {
        case .checking, .authorized:
            EmptyView()
        case .denied:
            scannerMessage("Camera access is off. Enable camera access in Settings or paste the pairing JSON below.")
        case .restricted:
            scannerMessage("Camera access is restricted on this iPhone. Paste the pairing JSON below.")
        case .unavailable:
            scannerMessage("Camera is unavailable. Paste the pairing JSON below.")
        }
    }

    private func scannerMessage(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
    }

    private func decodedPayloadView(_ payload: PairingQRCodePayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Mac Found", systemImage: "desktopcomputer")
                .font(.headline)

            LabeledContent("Device ID", value: payload.macDeviceId)
            LabeledContent("Fingerprint", value: payload.publicKeyFingerprint)

            if let expirationDate = payload.expirationDate {
                LabeledContent("Expires", value: expirationDate.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func submitScannedCode(_ code: String) async {
        guard !isPairing else {
            return
        }

        if code == lastScannedCode {
            return
        }

        lastScannedCode = code
        await submit(code)
    }

    private func submit(_ rawPayload: String) async {
        guard !isPairing else {
            return
        }

        isPairing = true
        defer { isPairing = false }

        do {
            let payload = try decoder.decode(rawPayload)
            decodedPayload = payload
            status = "Pairing with the Mac..."
            try await model.pair(with: payload)
            status = "Mac paired."
            manualPayload = ""
        } catch {
            status = PairingPayloadDecoder.displayText(for: error)
            lastScannedCode = nil
        }
    }
}
