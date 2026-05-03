import AVFoundation
import SwiftUI
import UIKit

enum QRCodeScannerAuthorizationState: Equatable {
    case checking
    case authorized
    case denied
    case restricted
    case unavailable
}

struct QRCodeScannerView: UIViewControllerRepresentable {
    @Binding var authorizationState: QRCodeScannerAuthorizationState
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.onCodeScanned = onCodeScanned
        controller.onAuthorizationStateChanged = { state in
            authorizationState = state
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {
        uiViewController.onCodeScanned = onCodeScanned
        uiViewController.onAuthorizationStateChanged = { state in
            authorizationState = state
        }
    }
}

final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    var onAuthorizationStateChanged: ((QRCodeScannerAuthorizationState) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        configureForCurrentAuthorization()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSessionIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let readableObject = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              readableObject.type == .qr,
              let value = readableObject.stringValue else {
            return
        }

        onCodeScanned?(value)
    }

    private func configureForCurrentAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            onAuthorizationStateChanged?(.authorized)
            configureSession()
        case .notDetermined:
            onAuthorizationStateChanged?(.checking)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }

                    if granted {
                        self.onAuthorizationStateChanged?(.authorized)
                        self.configureSession()
                        self.startSessionIfNeeded()
                    } else {
                        self.onAuthorizationStateChanged?(.denied)
                    }
                }
            }
        case .denied:
            onAuthorizationStateChanged?(.denied)
        case .restricted:
            onAuthorizationStateChanged?(.restricted)
        @unknown default:
            onAuthorizationStateChanged?(.unavailable)
        }
    }

    private func configureSession() {
        guard !isConfigured else {
            return
        }

        guard let device = AVCaptureDevice.default(for: .video) else {
            onAuthorizationStateChanged?(.unavailable)
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                onAuthorizationStateChanged?(.unavailable)
                return
            }
            captureSession.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else {
                onAuthorizationStateChanged?(.unavailable)
                return
            }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = view.bounds
            view.layer.insertSublayer(previewLayer, at: 0)
            self.previewLayer = previewLayer
            isConfigured = true
        } catch {
            onAuthorizationStateChanged?(.unavailable)
        }
    }

    private func startSessionIfNeeded() {
        guard isConfigured, !captureSession.isRunning else {
            return
        }

        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func stopSession() {
        guard captureSession.isRunning else {
            return
        }

        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }
}
