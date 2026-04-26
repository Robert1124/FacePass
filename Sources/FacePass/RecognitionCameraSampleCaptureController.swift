import AppKit
@preconcurrency import AVFoundation
import CoreImage
import FacePassCore
import SwiftUI
import Vision

final class RecognitionCameraSampleCaptureController: NSObject, FaceRecognitionModeSampleCapturing {
    private let sessionQueue = DispatchQueue(label: "com.facepass.recognition-camera-capture.session")
    private let sessionQueueKey = DispatchSpecificKey<Bool>()
    private let sampleQueue = DispatchQueue(label: "com.facepass.recognition-camera-capture.samples")
    private let stateLock = NSLock()
    private let imageContext = CIContext(options: nil)
    private var activeRunState: RecognitionCameraSampleCaptureRunState?
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var panelController: RecognitionCameraCapturePanelController?

    override init() {
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: true)
    }

    func captureSample(timeout: TimeInterval) async -> FaceSampleCaptureResult {
        await captureSample(timeout: timeout, mode: .enrollment)
    }

    func captureSample(
        timeout: TimeInterval,
        mode: FaceSampleCaptureMode
    ) async -> FaceSampleCaptureResult {
        let permissionStatus = await resolveCameraPermissionStatus()
        guard permissionStatus == .authorized else {
            await showTerminalState(.permissionDenied)
            return .permissionDenied
        }

        if Task.isCancelled {
            return .cancelled
        }

        let runState = RecognitionCameraSampleCaptureRunState(captureMode: mode)
        let session = AVCaptureSession()
        setActiveRunState(runState)
        setCaptureSession(session)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                runState.setContinuation(continuation)
                runState.setTimeoutTask(Task { [weak self, weak runState] in
                    let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else {
                        return
                    }
                    runState?.finishAfterTimeout { result in
                        self?.finishCapture(result)
                    }
                })

                Task { @MainActor [weak self] in
                    self?.showScanningPanel(session: session, mode: mode)
                }

                sessionQueue.async { [weak self, weak runState, session] in
                    guard let self, let runState, runState.shouldContinue else {
                        return
                    }

                    switch self.startSession(session) {
                    case .started:
                        guard runState.shouldContinue else {
                            self.stopSession()
                            return
                        }
                    case .failed:
                        runState.finish(.failed(.sessionStartFailed)) { [weak self] result in
                            self?.finishCapture(result)
                        }
                    }
                }
            }
        } onCancel: { [weak self, weak runState] in
            runState?.finish(.cancelled) { result in
                self?.finishCapture(result)
            }
        }
    }

    private func resolveCameraPermissionStatus() async -> CameraFaceDetectionPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { isGranted in
                    continuation.resume(returning: isGranted ? .authorized : .denied)
                }
            }
        @unknown default:
            return .unknown
        }
    }

    @MainActor
    private func showScanningPanel(session: AVCaptureSession, mode: FaceSampleCaptureMode) {
        if panelController == nil {
            panelController = RecognitionCameraCapturePanelController()
        }
        panelController?.show(session: session, state: .scanning, mode: mode)
    }

    private func showTerminalState(_ state: RecognitionCameraCaptureState) async {
        await MainActor.run {
            if panelController == nil {
                panelController = RecognitionCameraCapturePanelController()
            }
            panelController?.show(session: nil, state: state)
            panelController?.dismiss(after: 0.7)
        }
    }

    private func startSession(_ session: AVCaptureSession) -> CameraFaceDetectionSessionStartResult {
        do {
            try configure(session: session)
        } catch {
            stopSession()
            return .failed
        }

        session.startRunning()
        return session.isRunning ? .started : .failed
    }

    private func configure(session: AVCaptureSession) throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw RecognitionCameraCaptureError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw RecognitionCameraCaptureError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        guard session.canAddOutput(output) else {
            throw RecognitionCameraCaptureError.cannotAddOutput
        }
        session.addOutput(output)
        setVideoOutput(output)
    }

    private func finishCapture(_ result: FaceSampleCaptureResult) {
        clearActiveRunState()
        stopSession()

        Task { @MainActor [weak self] in
            self?.panelController?.show(session: nil, state: RecognitionCameraCaptureState(result: result))
            self?.panelController?.dismiss(after: 0.65)
        }
    }

    private func stopSession() {
        let state = takeCaptureState()

        let stop = {
            state.output?.setSampleBufferDelegate(nil, queue: nil)

            guard let session = state.session else {
                return
            }

            if session.isRunning {
                session.stopRunning()
            }

            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
        }

        if DispatchQueue.getSpecific(key: sessionQueueKey) == true {
            stop()
        } else {
            sessionQueue.sync(execute: stop)
        }
    }

    private func activeRunStateIfAvailable() -> RecognitionCameraSampleCaptureRunState? {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }
        return activeRunState
    }

    private func setActiveRunState(_ runState: RecognitionCameraSampleCaptureRunState) {
        stateLock.lock()
        activeRunState = runState
        stateLock.unlock()
    }

    private func setCaptureSession(_ session: AVCaptureSession) {
        stateLock.lock()
        captureSession = session
        videoOutput = nil
        stateLock.unlock()
    }

    private func setVideoOutput(_ output: AVCaptureVideoDataOutput) {
        stateLock.lock()
        videoOutput = output
        stateLock.unlock()
    }

    private func takeCaptureState() -> (
        session: AVCaptureSession?,
        output: AVCaptureVideoDataOutput?
    ) {
        stateLock.lock()
        let session = captureSession
        let output = videoOutput
        captureSession = nil
        videoOutput = nil
        stateLock.unlock()
        return (session, output)
    }

    private func clearActiveRunState() {
        stateLock.lock()
        activeRunState = nil
        stateLock.unlock()
    }

    private func handle(sampleBuffer: CMSampleBuffer, runState: RecognitionCameraSampleCaptureRunState) {
        guard let processedFrameCount = runState.beginProcessingFrame() else {
            return
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([request])
            let bounds = request.results?.map(\.boundingBox) ?? []

            if bounds.isEmpty {
                runState.completeProcessingFrame()
                return
            }

            if runState.captureMode == .enrollment, bounds.count != 1 {
                runState.finish(.multipleFaces) { [weak self] result in
                    self?.finishCapture(result)
                }
                return
            }

            guard bounds.allSatisfy(\.isValidVisionNormalizedFaceBounds) else {
                runState.finish(.failed(.invalidFaceBounds)) { [weak self] result in
                    self?.finishCapture(result)
                }
                return
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                runState.finish(.noUsableSample(.missingPixelBuffer)) { [weak self] result in
                    self?.finishCapture(result)
                }
                return
            }

            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = imageContext.createCGImage(image, from: image.extent) else {
                runState.finish(.noUsableSample(.cgImageCreationFailed)) { [weak self] result in
                    self?.finishCapture(result)
                }
                return
            }

            let samples = bounds.map { bounds in
                FaceEnrollmentSample(
                    image: cgImage,
                    visionNormalizedFaceBounds: bounds
                )
            }
            runState.recordCapturedSample(FaceSampleCaptureSummary(
                samples: samples,
                processedFrameCount: processedFrameCount
            ))
        } catch {
            runState.finish(.failed(.faceDetectionFailed)) { [weak self] result in
                self?.finishCapture(result)
            }
        }
    }
}

extension RecognitionCameraSampleCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let runState = activeRunStateIfAvailable() else {
            return
        }

        handle(sampleBuffer: sampleBuffer, runState: runState)
    }
}

extension RecognitionCameraSampleCaptureController: @unchecked Sendable {}

private enum RecognitionCameraCaptureError: Error {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
}

private final class RecognitionCameraSampleCaptureRunState: @unchecked Sendable {
    let captureMode: FaceSampleCaptureMode
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FaceSampleCaptureResult, Never>?
    private var completedResult: FaceSampleCaptureResult?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false
    private var isProcessingFrame = false
    private var processedFrameCount = 0
    private var latestCapturedSummary: FaceSampleCaptureSummary?

    init(captureMode: FaceSampleCaptureMode) {
        self.captureMode = captureMode
    }

    var shouldContinue: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return !isFinished
    }

    func setContinuation(_ continuation: CheckedContinuation<FaceSampleCaptureResult, Never>) {
        var resultToResume: FaceSampleCaptureResult?
        lock.lock()
        if let completedResult {
            resultToResume = completedResult
        } else {
            self.continuation = continuation
        }
        lock.unlock()

        if let resultToResume {
            continuation.resume(returning: resultToResume)
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        var shouldCancel = false
        lock.lock()
        if isFinished {
            shouldCancel = true
        } else {
            timeoutTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func beginProcessingFrame() -> Int? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !isFinished, !isProcessingFrame else {
            return nil
        }

        isProcessingFrame = true
        processedFrameCount += 1
        return processedFrameCount
    }

    func completeProcessingFrame() {
        lock.lock()
        isProcessingFrame = false
        lock.unlock()
    }

    func recordCapturedSample(_ summary: FaceSampleCaptureSummary) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        latestCapturedSummary = summary
        isProcessingFrame = false
        lock.unlock()
    }

    func finishAfterTimeout(
        cleanup: @escaping (FaceSampleCaptureResult) -> Void
    ) {
        var continuationToResume: CheckedContinuation<FaceSampleCaptureResult, Never>?
        var timeoutTaskToCancel: Task<Void, Never>?
        let result: FaceSampleCaptureResult

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        if let latestCapturedSummary {
            result = .captured(latestCapturedSummary)
        } else {
            result = .timedOut
        }
        isFinished = true
        isProcessingFrame = false
        completedResult = result
        continuationToResume = continuation
        continuation = nil
        timeoutTaskToCancel = timeoutTask
        timeoutTask = nil
        self.latestCapturedSummary = nil
        lock.unlock()

        timeoutTaskToCancel?.cancel()
        cleanup(result)
        continuationToResume?.resume(returning: result)
    }

    func finish(
        _ result: FaceSampleCaptureResult,
        cleanup: @escaping (FaceSampleCaptureResult) -> Void
    ) {
        var continuationToResume: CheckedContinuation<FaceSampleCaptureResult, Never>?
        var timeoutTaskToCancel: Task<Void, Never>?

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        isFinished = true
        isProcessingFrame = false
        completedResult = result
        continuationToResume = continuation
        continuation = nil
        timeoutTaskToCancel = timeoutTask
        timeoutTask = nil
        latestCapturedSummary = nil
        lock.unlock()

        timeoutTaskToCancel?.cancel()
        cleanup(result)
        continuationToResume?.resume(returning: result)
    }
}

@MainActor
private final class RecognitionCameraCapturePanelController {
    private let viewModel = RecognitionCameraCaptureViewModel()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private let panelSize = NSSize(width: 332, height: 428)
    private let topInset: CGFloat = 36

    func show(
        session: AVCaptureSession?,
        state: RecognitionCameraCaptureState,
        mode: FaceSampleCaptureMode? = nil
    ) {
        dismissTask?.cancel()
        viewModel.session = session
        viewModel.state = state
        if let mode {
            viewModel.captureMode = mode
        }

        let panel = ensurePanel()
        let targetFrame = targetFrame(on: panel.screen ?? NSScreen.main)
        let startFrame = targetFrame.offsetBy(dx: 0, dy: panelSize.height + topInset)

        if !panel.isVisible {
            panel.setFrame(startFrame, display: false)
        }

        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func dismiss(after delay: TimeInterval = 0) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                self?.viewModel.session = nil
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: RecognitionCameraCaptureView(viewModel: viewModel))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        self.panel = panel
        return panel
    }

    private func targetFrame(on screen: NSScreen?) -> NSRect {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.maxY - panelSize.height - topInset

        return NSRect(
            x: x.rounded(.toNearestOrAwayFromZero),
            y: y.rounded(.toNearestOrAwayFromZero),
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

@MainActor
private final class RecognitionCameraCaptureViewModel: ObservableObject {
    @Published var session: AVCaptureSession?
    @Published var state: RecognitionCameraCaptureState = .scanning
    @Published var captureMode: FaceSampleCaptureMode = .enrollment
}

private enum RecognitionCameraCaptureState: Equatable {
    case scanning
    case captured
    case permissionDenied
    case timedOut
    case multipleFaces
    case failed

    init(result: FaceSampleCaptureResult) {
        switch result {
        case .captured:
            self = .captured
        case .permissionDenied:
            self = .permissionDenied
        case .timedOut:
            self = .timedOut
        case .multipleFaces:
            self = .multipleFaces
        case .cancelled, .noFace, .noUsableSample, .failed:
            self = .failed
        }
    }

    var title: String {
        switch self {
        case .scanning:
            "FacePass Recognition"
        case .captured:
            "Sample Captured"
        case .permissionDenied:
            "Camera Permission Needed"
        case .timedOut:
            "No Face Captured"
        case .multipleFaces:
            "One Face Required"
        case .failed:
            "Capture Failed"
        }
    }

    func detail(for mode: FaceSampleCaptureMode) -> String? {
        switch self {
        case .scanning:
            switch mode {
            case .enrollment:
                "Keep one face centered in the frame."
            case .recognition:
                "Keep visible faces centered in the frame."
            }
        case .captured:
            nil
        case .permissionDenied:
            "Allow camera access to capture a local sample."
        case .timedOut:
            "The short camera window ended."
        case .multipleFaces:
            "Try again with only one visible face."
        case .failed:
            "The sample was not usable."
        }
    }

    var systemImageName: String {
        switch self {
        case .scanning:
            "viewfinder"
        case .captured:
            "checkmark"
        case .permissionDenied:
            "video.slash"
        case .timedOut:
            "clock"
        case .multipleFaces:
            "person.2.slash"
        case .failed:
            "xmark"
        }
    }

    var accentColor: Color {
        switch self {
        case .scanning:
            .white
        case .captured:
            .green
        case .permissionDenied, .multipleFaces, .failed:
            .red
        case .timedOut:
            .orange
        }
    }
}

private struct RecognitionCameraCaptureView: View {
    @ObservedObject var viewModel: RecognitionCameraCaptureViewModel
    @State private var isScanning = false
    private let panelSize = CGSize(width: 332, height: 428)
    private let panelCornerRadius: CGFloat = 34
    private let statusRegionHeight: CGFloat = 110

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .fill(.black)

            RecognitionCameraPreview(session: viewModel.session)
                .opacity(viewModel.session == nil ? 0 : 1)
                .frame(width: panelSize.width, height: panelSize.height)

            cameraReadabilityOverlay

            scanLine

            VStack(spacing: 0) {
                headerContent
                    .frame(height: 22, alignment: .top)
                    .padding(.top, 16)

                Spacer(minLength: 0)

                statusContent
                    .frame(height: statusRegionHeight, alignment: .top)
                    .padding(.bottom, 26)
            }
            .padding(.horizontal, 22)
        }
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .frame(width: panelSize.width, height: panelSize.height)
        .background(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            updateScanningAnimation(for: viewModel.state)
        }
        .onChange(of: viewModel.state) { state in
            updateScanningAnimation(for: state)
        }
    }

    @ViewBuilder
    private var scanLine: some View {
        if viewModel.state == .scanning {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.88), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: panelSize.width, height: 2)
                .offset(y: isScanning ? panelSize.height * 0.42 : -panelSize.height * 0.42)
                .shadow(color: .white.opacity(0.75), radius: 9)
                .animation(.easeInOut(duration: 1.08).repeatForever(autoreverses: true), value: isScanning)
        }
    }

    private var cameraReadabilityOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)

            LinearGradient(
                colors: [
                    .black.opacity(0.76),
                    .black.opacity(0.32),
                    .black.opacity(0.18),
                    .black.opacity(0.68)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var headerContent: some View {
        HStack(spacing: 9) {
            Image(systemName: "viewfinder")
                .font(.system(size: 16, weight: .semibold))
            Text("FacePass")
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.94))
        .shadow(color: .black.opacity(0.75), radius: 8, y: 2)
    }

    private var statusContent: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(viewModel.state.accentColor.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: viewModel.state.systemImageName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(viewModel.state.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let detail = viewModel.state.detail(for: viewModel.captureMode) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 230)
            }
        }
        .shadow(color: .black.opacity(0.75), radius: 8, y: 2)
    }

    private var accessibilityLabel: String {
        guard let detail = viewModel.state.detail(for: viewModel.captureMode) else {
            return viewModel.state.title
        }

        return "\(viewModel.state.title). \(detail)"
    }

    private func updateScanningAnimation(for state: RecognitionCameraCaptureState) {
        guard state == .scanning else {
            isScanning = false
            return
        }

        isScanning = false
        DispatchQueue.main.async {
            isScanning = true
        }
    }
}

private struct RecognitionCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.setSession(session)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.setSession(session)
    }

    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) {
        nsView.setSession(nil)
    }
}

private final class PreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutPreviewLayer()
    }

    override func layout() {
        super.layout()
        layoutPreviewLayer()
    }

    func setSession(_ session: AVCaptureSession?) {
        previewLayer.session = session
        layoutPreviewLayer()
    }

    private func configureLayers() {
        wantsLayer = true

        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.masksToBounds = true
        layer = rootLayer

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.masksToBounds = true
        rootLayer.addSublayer(previewLayer)
        layoutPreviewLayer()
    }

    private func layoutPreviewLayer() {
        guard let layer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.masksToBounds = true
        layer.backgroundColor = NSColor.black.cgColor

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        previewLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        previewLayer.masksToBounds = true
        configurePreviewConnectionForDisplayLayerMirroring()
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        CATransaction.commit()
    }

    private func configurePreviewConnectionForDisplayLayerMirroring() {
        guard let connection = previewLayer.connection else {
            return
        }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }
}

private extension CGRect {
    var isValidVisionNormalizedFaceBounds: Bool {
        minX.isFinite &&
            minY.isFinite &&
            width.isFinite &&
            height.isFinite &&
            width > 0 &&
            height > 0 &&
            minX >= 0 &&
            minY >= 0 &&
            maxX <= 1 &&
            maxY <= 1
    }
}
