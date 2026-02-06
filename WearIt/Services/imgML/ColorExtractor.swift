//
//  ColorExtractor.swift
//  WearIt
//
//  Created by Dor David on 21/10/2025.
//

import UIKit
import CoreGraphics

struct DominantColor {
    let hex: String
    let name: String
    let ratio: Double // אחוז משוער מהפיקסלים התקפים
}

enum ColorExtractor {
    /// מחלץ עד N צבעים דומיננטיים מ־UIImage עם אלפא (נשען על אלפא>0 כדי להתעלם מהרקע)
    static func extract(from cutout: UIImage, maxColors: Int = 3) -> [DominantColor] {
        guard let cg = cutout.cgImage else { return [] }

        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return [] }

        // דאונסקייל עד גודל סביר (לשיפור מהירות)
        let maxSide = 256
        let scale = min(1.0, Double(maxSide) / Double(max(width, height)))
        let newW = max(1, Int(Double(width) * scale))
        let newH = max(1, Int(Double(height) * scale))

        guard let ctx = CGContext(
            data: nil,
            width: newW, height: newH,
            bitsPerComponent: 8,
            bytesPerRow: newW * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let buf = ctx.data else { return [] }
        let px = buf.bindMemory(to: UInt8.self, capacity: newW * newH * 4)

        // אוספים רק פיקסלים עם אלפא משמעותית
        var points: [(r: Double,g: Double,b: Double)] = []
        points.reserveCapacity(newW * newH / 3)

        for y in 0..<newH {
            for x in 0..<newW {
                let i = (y * newW + x) * 4
                let r = px[i], g = px[i+1], b = px[i+2], a = px[i+3]
                if a > 16 { // אלפא>~6% → פיקסל של הבגד
                    points.append((Double(r), Double(g), Double(b)))
                }
            }
        }
        guard !points.isEmpty else { return [] }

        // K-Means קטן
        let k = min(maxColors, max(1, Int(round(Double(points.count).squareRoot()/8))))
        let clusters = kmeans(points: points, k: k, iters: 8)

        // מיון לפי גודל אשכול
        let sorted = clusters.sorted { $0.points.count > $1.points.count }
        let total = Double(points.count)
        return sorted.map { c in
            let r = UInt8(max(0, min(255, Int(c.center.r.rounded()))))
            let g = UInt8(max(0, min(255, Int(c.center.g.rounded()))))
            let b = UInt8(max(0, min(255, Int(c.center.b.rounded()))))
            let hex = String(format:"#%02X%02X%02X", r,g,b)
            let name = humanColorName(r: Int(r), g: Int(g), b: Int(b))
            return DominantColor(hex: hex, name: name, ratio: Double(c.points.count)/total)
        }
    }

    // MARK: - KMeans (פשוט ומהיר)
    private struct Cluster { var center:(r:Double,g:Double,b:Double); var points:[(Double,Double,Double)] }
    private static func kmeans(points: [(Double,Double,Double)], k: Int, iters: Int) -> [Cluster] {
        var centers = (0..<k).map { _ in points[Int.random(in: 0..<points.count)] }
        var clusters = [Cluster](repeating: .init(center:(0,0,0), points: []), count: k)

        for _ in 0..<iters {
            for i in 0..<k { clusters[i].points.removeAll(keepingCapacity: true) }
            for p in points {
                var bi = 0; var bd = Double.greatestFiniteMagnitude
                for i in 0..<k {
                    let c = centers[i]
                    let d = (p.0-c.0)*(p.0-c.0)+(p.1-c.1)*(p.1-c.1)+(p.2-c.2)*(p.2-c.2)
                    if d < bd { bd = d; bi = i }
                }
                clusters[bi].points.append(p)
            }
            for i in 0..<k {
                if clusters[i].points.isEmpty { centers[i] = points[Int.random(in: 0..<points.count)]; continue }
                let s = clusters[i].points.reduce((0.0,0.0,0.0)) { ($0.0+$1.0,$0.1+$1.1,$0.2+$1.2) }
                let c = (s.0/Double(clusters[i].points.count), s.1/Double(clusters[i].points.count), s.2/Double(clusters[i].points.count))
                centers[i] = c
                clusters[i].center = c
            }
        }
        return clusters
    }

    // MARK: - שמות “אנושיים”
    private static func humanColorName(r: Int, g: Int, b: Int) -> String {
        // מפה קטנה ומהירה; אפשר להחליף לטבלת nearest-named-color גדולה יותר בהמשך
        let hsv = rgb2hsv(r,g,b)
        let v = hsv.v, s = hsv.s, h = hsv.h
        if v < 0.15 { return "black" }
        if v > 0.95 && s < 0.1 { return "white" }
        if s < 0.12 { return "gray" }
        switch h {
        case 0..<15, 345...360: return "red"
        case 15..<35: return v < 0.6 ? "brown" : "orange"
        case 35..<65: return "yellow"
        case 65..<95: return "olive"
        case 95..<150: return "green"
        case 150..<190: return "teal"
        case 190..<225: return "blue"
        case 225..<255: return "navy"
        case 255..<290: return "purple"
        case 290..<345: return "pink"
        default: return "color"
        }
    }

    private static func rgb2hsv(_ r:Int,_ g:Int,_ b:Int)->(h:Double,s:Double,v:Double){
        let rf=Double(r)/255, gf=Double(g)/255, bf=Double(b)/255
        let maxv=max(rf,gf,bf), minv=min(rf,gf,bf), d=maxv-minv
        var h:Double=0
        if d != 0 {
            if maxv==rf { h = 60*(((gf-bf)/d).truncatingRemainder(dividingBy: 6)) }
            else if maxv==gf { h = 60*(((bf-rf)/d)+2) }
            else { h = 60*(((rf-gf)/d)+4) }
            if h < 0 { h += 360 }
        }
        let s = maxv==0 ? 0 : d/maxv
        return (h,s,maxv)
    }
}
