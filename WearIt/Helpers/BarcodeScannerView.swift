//
//  BarcodeScannerView.swift
//  WearIt
//
//  Created by Dor David on 05/09/2025.
//

import SwiftUI
import AVFoundation

struct BarcodeScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .black

        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return vc }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return vc }
        session.addOutput(output)

        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.ean13, .ean8, .upce, .code128, .qr, .pdf417]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = UIScreen.main.bounds
        vc.view.layer.addSublayer(preview)

        // ריבוע פוקוס
        let box = CAShapeLayer()
        box.strokeColor = UIColor.white.cgColor
        box.lineWidth = 2
        box.fillColor = UIColor.clear.cgColor
        let rect = CGRect(x: UIScreen.main.bounds.midX - 120, y: UIScreen.main.bounds.midY - 60, width: 240, height: 120)
        box.path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
        vc.view.layer.addSublayer(box)

        session.startRunning()
        context.coordinator.session = session
        context.coordinator.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var session: AVCaptureSession?
        var onCode: ((String) -> Void)?

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let code = obj.stringValue else { return }
            onCode?(code)
            session?.stopRunning()
        }
    }
}
