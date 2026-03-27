import SwiftUI
import AVFoundation

/// Native barcode scanner using AVFoundation camera
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onBarcodeFound: (String) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> BarcodeScannerViewController {
        let vc = BarcodeScannerViewController()
        vc.onBarcodeFound = { barcode in
            onBarcodeFound(barcode)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: BarcodeScannerViewController, context: Context) {}
}

class BarcodeScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onBarcodeFound: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasFoundBarcode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if captureSession?.isRunning == false {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession?.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession?.isRunning == true {
            captureSession?.stopRunning()
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showNoCameraLabel()
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            output.metadataObjectTypes = [
                .ean8, .ean13, .upce, .code128, .code39, .code93,
                .itf14, .dataMatrix, .qr
            ]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.layer.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview

        // Add scan guide overlay
        addScanGuide()

        captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func addScanGuide() {
        let guideView = UIView()
        guideView.translatesAutoresizingMaskIntoConstraints = false
        guideView.layer.borderColor = UIColor.systemBlue.cgColor
        guideView.layer.borderWidth = 2
        guideView.layer.cornerRadius = 12
        guideView.backgroundColor = .clear
        view.addSubview(guideView)

        NSLayoutConstraint.activate([
            guideView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guideView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            guideView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.75),
            guideView.heightAnchor.constraint(equalToConstant: 120),
        ])

        let label = UILabel()
        label.text = "Align barcode within frame"
        label.textColor = .white
        label.font = .systemFont(ofSize: 14)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: guideView.bottomAnchor, constant: 16),
        ])
    }

    private func showNoCameraLabel() {
        let label = UILabel()
        label.text = "Camera not available"
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasFoundBarcode,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let barcode = object.stringValue else { return }

        hasFoundBarcode = true
        captureSession?.stopRunning()

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        onBarcodeFound?(barcode)
    }
}
