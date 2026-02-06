//
//  ImagePostprocess.swift
//  WearIt
//
//  Created by Dor David on 05/09/2025.
//

import UIKit
import CoreImage
import AVFoundation
import CoreImage.CIFilterBuiltins

enum PostError: Error { case ciFail }

struct ImagePostprocess {
    /// חותך שקיפויות מסביב (bounding box של פיקסלים עם אלפא > thresh)
    static func autoCropAlpha(_ ui: UIImage, alphaThreshold: UInt8 = 4) throws -> UIImage {
        guard let cg = ui.cgImage else { throw PostError.ciFail }
        let w = cg.width, h = cg.height
        let bytesPerPixel = 4, bytesPerRow = bytesPerPixel * w

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { throw PostError.ciFail }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PostError.ciFail }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data else { throw PostError.ciFail }
        let p = buf.bindMemory(to: UInt8.self, capacity: w*h*bytesPerPixel)

        var minX = w, minY = h, maxX = 0, maxY = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y*w + x) * bytesPerPixel
                let a = p[i+3]
                if a > alphaThreshold {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }

        if minX >= maxX || minY >= maxY {
            return ui // אין מה לחתוך
        }

        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cgOut = cg.cropping(to: crop) else { throw PostError.ciFail }
        return UIImage(cgImage: cgOut, scale: ui.scale, orientation: ui.imageOrientation)
    }

    /// מניח את הפריט על קנבס אחיד עם שוליים וצל רך (תמונת “חנות”)
    static func placeOnCanvas(_ ui: UIImage,
                              canvas: CGSize = .init(width: 1024, height: 1024),
                              background: UIColor = .white,
                              padding: CGFloat = 80,
                              shadowRadius: CGFloat = 18,
                              shadowOpacity: CGFloat = 0.18,
                              shadowOffset: CGSize = .init(width: 0, height: 10),
                              outputJPEG: Bool = true,
                              jpegQuality: CGFloat = 0.9) throws -> Data {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = ui.scale
        fmt.opaque = true

        let img = UIGraphicsImageRenderer(size: canvas, format: fmt).image { ctx in
            let cgctx = ctx.cgContext
            // רקע
            cgctx.setFillColor(background.cgColor)
            cgctx.fill(CGRect(origin: .zero, size: canvas))

            // חשב ריבוע יעד עם padding ושמירת יחס
            let maxRect = CGRect(x: padding, y: padding,
                                 width: canvas.width - 2*padding,
                                 height: canvas.height - 2*padding)
            let fitted = AVMakeRect(aspectRatio: ui.size, insideRect: maxRect)

            // צל רך מאחורי הפריט
            cgctx.saveGState()
            cgctx.setShadow(offset: shadowOffset,
                            blur: shadowRadius,
                            color: UIColor.black.withAlphaComponent(shadowOpacity).cgColor)
            ui.draw(in: fitted)
            cgctx.restoreGState()
        }

        if outputJPEG {
            guard let data = img.jpegData(compressionQuality: jpegQuality) else { throw PostError.ciFail }
            return data
        } else {
            guard let data = img.pngData() else { throw PostError.ciFail }
            return data
        }
    }
}
