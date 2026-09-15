//
//  BarcodeScannerView.swift
//  WearIt
//

import SwiftUI
import AVFoundation

/// Full-screen barcode scanner with close button.
struct BarcodeScannerScreen: View {
    var onCode: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            BarcodeScannerView(onCode: onCode)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button(String(localized: "action_close"), action: onCancel)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.sm)

                Spacer()

                    Text(String(localized: "barcode_scan_hint"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 48)
            }
        }
        .statusBarHidden(true)
    }
}

struct BarcodeScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        uiViewController.onCode = onCode
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didEmitCode = false
    private let boxLayer = CAShapeLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        configureFocusBox()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        updateFocusBoxPath()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        didEmitCode = false
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Product barcodes and QR codes (GTIN in URL or product-page link) are handled in lookup.
        let supported: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128, .qr]
        output.metadataObjectTypes = supported.filter { output.availableMetadataObjectTypes.contains($0) }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    private func configureFocusBox() {
        boxLayer.strokeColor = UIColor.white.cgColor
        boxLayer.lineWidth = 2
        boxLayer.fillColor = UIColor.clear.cgColor
        view.layer.addSublayer(boxLayer)
        updateFocusBoxPath()
    }

    private func updateFocusBoxPath() {
        let width: CGFloat = min(view.bounds.width - 48, 280)
        let height: CGFloat = 140
        let rect = CGRect(
            x: (view.bounds.width - width) / 2,
            y: (view.bounds.height - height) / 2,
            width: width,
            height: height
        )
        boxLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 12).cgPath
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didEmitCode,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = obj.stringValue,
              !code.isEmpty else { return }

        didEmitCode = true
        session.stopRunning()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode?(code)
    }
}
