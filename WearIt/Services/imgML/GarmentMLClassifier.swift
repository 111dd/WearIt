//
//  GarmentMLClassifier.swift
//  WearIt
//
//  Created by Dor David on 21/10/2025.
//

import CoreML
import Vision
import UIKit

struct GarmentPrediction {
    let label: String
    let confidence: Float
}

enum GarmentMLClassifier {
    /// מנסה לטעון את המודל המאומן שלך (שם הקובץ ב־Bundle)
    private static func vnModel() -> VNCoreMLModel? {
        // החלף לשם המודל שלך אם שונה:
        guard let url = Bundle.main.url(forResource: "GarmentCategory", withExtension: "mlmodelc") ??
                        Bundle.main.url(forResource: "GarmentCategory", withExtension: "mlmodel") else { return nil }
        do {
            let compiled = url.pathExtension == "mlmodel" ? try MLModel.compileModel(at: url) : url
            let model = try MLModel(contentsOf: compiled)
            return try VNCoreMLModel(for: model)
        } catch {
            print("GarmentMLClassifier load error:", error.localizedDescription)
            return nil
        }
    }

    /// סיווג מהיר על UIImage (אפשר להזין לו את תמונת ה־cutout או המקורית—מומלץ cutout)
    static func classify(_ image: UIImage) async -> GarmentPrediction? {
        guard let cg = image.cgImage, let model = vnModel() else { return nil }
        let req = VNCoreMLRequest(model: model)
        req.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
        do {
            try handler.perform([req])
            guard let res = (req.results as? [VNClassificationObservation])?.first else { return nil }
            return GarmentPrediction(label: res.identifier, confidence: res.confidence)
        } catch {
            print("VN classify failed:", error.localizedDescription)
            return nil
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
