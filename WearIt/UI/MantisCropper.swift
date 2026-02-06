//
//  MantisCropper.swift
//  WearIt
//
//  SwiftUI wrapper around Mantis crop view controller (with fallback).
//

import SwiftUI

#if canImport(Mantis)
import Mantis

struct MantisCropper: UIViewControllerRepresentable {
    let image: UIImage
    let onCancel: () -> Void
    let onCropped: (UIImage) -> Void
    var fixedRatio: CGFloat? = nil  // e.g., 1.0 for square. nil = free/ratios menu.

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> CropViewController {
        var config = Mantis.Config()
        if let ratio = fixedRatio {
            config.presetFixedRatioType = .alwaysUsingOnePresetFixedRatio(ratio: ratio)
        } else {
            config.presetFixedRatioType = .canUseMultiplePresetFixedRatio()
        }
        config.showAttachedCropToolbar = true
        let vc = Mantis.cropViewController(image: image, config: config)
        vc.modalPresentationStyle = .fullScreen
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: CropViewController, context: Context) {}

    class Coordinator: NSObject, CropViewControllerDelegate {
        let parent: MantisCropper
        init(_ parent: MantisCropper) { self.parent = parent }

        func cropViewControllerDidCrop(_ cropViewController: CropViewController, cropped: UIImage, transformation: Transformation) {
            parent.onCropped(cropped)
            cropViewController.dismiss(animated: true)
        }

        func cropViewControllerDidCancel(_ cropViewController: CropViewController, original: UIImage) {
            parent.onCancel()
            cropViewController.dismiss(animated: true)
        }
    }
}
#else
/// Fallback stub when Mantis package is unavailable; just returns the original image.
struct MantisCropper: View {
    let image: UIImage
    let onCancel: () -> Void
    let onCropped: (UIImage) -> Void
    var fixedRatio: CGFloat? = nil

    var body: some View {
        VStack(spacing: 12) {
            Text("Cropper unavailable")
                .font(.headline)
            HStack {
                Button("Cancel", action: onCancel)
                Button("Use Image") { onCropped(image) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
#endif


