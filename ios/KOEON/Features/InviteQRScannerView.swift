import AVFoundation
import SwiftUI

struct InviteQRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> InviteQRScannerViewController {
        InviteQRScannerViewController(onCode: onCode, onError: onError)
    }

    func updateUIViewController(_ uiViewController: InviteQRScannerViewController, context: Context) {}
}

final class InviteQRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "org.example.koeon.qr-camera")
    private let onCode: (String) -> Void
    private let onError: (String) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delivered = false

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { granted ? self?.configure() : self?.fail("Camera permission was denied") }
            }
        default: fail("Camera permission is unavailable. Use a temporary code or Invite URL.")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configure() {
        do {
            guard let camera = AVCaptureDevice.default(for: .video) else { return fail("Camera is unavailable") }
            let input = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(input) else { return fail("Camera input is unavailable") }
            captureSession.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else { return fail("QR scanner is unavailable") }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: captureSession)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            previewLayer = preview
            sessionQueue.async { [captureSession] in captureSession.startRunning() }
        } catch { fail("Camera could not start") }
    }

    private func fail(_ message: String) {
        guard !delivered else { return }
        delivered = true
        onError(message)
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        delivered = true
        sessionQueue.async { [captureSession] in captureSession.stopRunning() }
        onCode(value)
    }
}
