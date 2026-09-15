//
//  WearItPerformance.swift
//  WearIt
//
//  Lightweight signpost helpers for performance-critical paths.
//  Do not log private paths, garment names, or personal data.
//

import Foundation
import UIKit
import os

enum WearItPerformance {
    static let subsystem = "com.dordavid.WearIt.performance"

    enum SignpostCategory {
        static let images = "Images"
        static let widget = "Widget"
        static let bootstrap = "Bootstrap"
    }
}

extension UIImage {
    /// Approximate decoded byte cost for NSCache cost tracking.
    var wearItApproximateByteCost: Int {
        let bytesPerPixel = 4
        return Int(size.width * scale) * Int(size.height * scale) * bytesPerPixel
    }
}
