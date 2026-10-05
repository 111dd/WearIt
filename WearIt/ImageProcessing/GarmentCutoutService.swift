//
//  GarmentCutoutService.swift
//  WearIt
//
//  On-device garment cutout with choices. One Vision pass finds:
//  - separate items in the photo (foreground instances), so the user can
//    pick one when several garments share the frame (small clutter such as
//    hangers or tags is dropped);
//  - a person wearing the clothes (mirror selfie): body pose splits the
//    person into top / bottom / shoes bands instead of cutting out the body;
//  - photo problems worth a retake (item cut off at the edge, too small, too dark).
//  Every cutout is trimmed to the garment and framed with even transparent
//  padding so the wardrobe reads like one catalog.
//
//  Runs synchronously; call from a background task. Returns nil when Vision
//  finds nothing (e.g. on the Simulator) so callers fall back to `ImageCutout`.
//

import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

struct CutoutCandidate: Identifiable {
    enum Kind: Equatable {
        case whole
        case item(Int)
        case worn(Category)
    }

    let id = UUID()
    let kind: Kind
    let image: UIImage
    /// Category implied by where the cutout came from (a body band).
    var categoryHint: Category? {
        if case .worn(let category) = kind { return category }
        return nil
    }

    var title: String {
        switch kind {
        case .whole: return String(localized: "cutout_choice_all")
        case .item(let number): return String(format: String(localized: "cutout_choice_item_format"), number)
        case .worn(let category): return category.title
        }
    }
}

enum CutoutQualityIssue: String, Equatable {
    case cutOffAtEdge
    case tooSmall
    case tooDark

    var message: String {
        switch self {
        case .cutOffAtEdge: return String(localized: "cutout_issue_cut_off")
        case .tooSmall: return String(localized: "cutout_issue_small")
        case .tooDark: return String(localized: "cutout_issue_dark")
        }
    }
}

struct CutoutResult {
    let candidates: [CutoutCandidate]
    let selectedIndex: Int
    let issues: [CutoutQualityIssue]

    var selected: CutoutCandidate { candidates[selectedIndex] }
}

enum GarmentCutoutService {
    private static let maxSide: CGFloat = 1536
    /// Instances smaller than this share of the largest one are clutter.
    private static let clutterRatio = 0.25
    private static let maxItemChoices = 4
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func analyze(_ source: UIImage, preferredCategory: Category? = nil) -> CutoutResult? {
        guard let cg = normalizedCGImage(source) else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)

        let foreground = VNGenerateForegroundInstanceMaskRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let pose = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([foreground, humans, pose]) } catch { return nil }

        guard let observation = foreground.results?.first,
              !observation.allInstances.isEmpty,
              let stats = InstanceStats(observation.instanceMask),
              let fullMask = try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler
              ) else { return nil }

        let input = CIImage(cgImage: cg)
        var candidates: [CutoutCandidate] = []
        var selectedIndex = 0
        var issues: [CutoutQualityIssue] = []

        // MARK: Worn on a person → body bands
        let bands = wornBands(humans: humans.results ?? [], poses: pose.results ?? [])
        if !bands.isEmpty {
            let mask = CIImage(cvPixelBuffer: fullMask)
            let personBox = stats.boundingBox(of: observation.allInstances)
            for band in bands {
                let box = personBox.intersection(band.rect)
                guard !box.isNull, box.width > 0.03, box.height > 0.03,
                      let image = render(input, mask: mask, normalizedBox: box, band: band.rect,
                                         size: CGSize(width: width, height: height)) else { continue }
                candidates.append(CutoutCandidate(kind: .worn(band.category), image: image))
            }
            if !candidates.isEmpty {
                selectedIndex = candidates.firstIndex { $0.categoryHint == preferredCategory }
                    ?? candidates.firstIndex { $0.categoryHint == .top } ?? 0
            }
        }

        // MARK: Loose items → main set, one choice per item
        if candidates.isEmpty {
            let main = stats.mainInstances(clutterRatio: clutterRatio)
            guard !main.isEmpty else { return nil }
            func cutout(_ set: IndexSet) -> UIImage? {
                guard let buffer = try? observation.generateScaledMaskForImage(forInstances: set, from: handler)
                else { return nil }
                return render(input, mask: CIImage(cvPixelBuffer: buffer),
                              normalizedBox: stats.boundingBox(of: set), band: nil,
                              size: CGSize(width: width, height: height))
            }
            if let whole = cutout(IndexSet(main)) {
                candidates.append(CutoutCandidate(kind: .whole, image: whole))
            }
            if main.count > 1 {
                for (offset, instance) in main.prefix(maxItemChoices).enumerated() {
                    if let image = cutout(IndexSet(integer: instance)) {
                        candidates.append(CutoutCandidate(kind: .item(offset + 1), image: image))
                    }
                }
            }
            guard !candidates.isEmpty else { return nil }

            let mainSet = IndexSet(main)
            if stats.coverage(of: mainSet) < 0.03 { issues.append(.tooSmall) }
            if stats.borderShare(of: mainSet) > 0.04 { issues.append(.cutOffAtEdge) }
        }

        if meanLuminance(input) < 0.14 { issues.append(.tooDark) }
        return CutoutResult(candidates: candidates, selectedIndex: selectedIndex, issues: issues)
    }

    // MARK: - Body bands

    private struct Band {
        let category: Category
        /// Normalized, top-left origin.
        let rect: CGRect
    }

    private static func wornBands(humans: [VNHumanObservation],
                                  poses: [VNHumanBodyPoseObservation]) -> [Band] {
        // A person large enough to be the subject, not a passer-by.
        guard humans.contains(where: { $0.confidence > 0.5 && $0.boundingBox.height > 0.35 }),
              let body = poses.max(by: { $0.confidence < $1.confidence }),
              let points = try? body.recognizedPoints(.all) else { return [] }

        func y(_ names: [VNHumanBodyPoseObservation.JointName]) -> CGFloat? {
            let found = names.compactMap { points[$0] }.filter { $0.confidence > 0.3 }
            guard !found.isEmpty else { return nil }
            // Vision is bottom-left; bands are top-left.
            return 1 - found.map(\.location.y).reduce(0, +) / CGFloat(found.count)
        }

        guard let shoulders = y([.leftShoulder, .rightShoulder]),
              let hips = y([.leftHip, .rightHip]), hips > shoulders else { return [] }
        let torso = hips - shoulders
        let ankles = y([.leftAnkle, .rightAnkle])

        func band(_ category: Category, _ top: CGFloat, _ bottom: CGFloat) -> Band? {
            let t = max(0, top), b = min(1, bottom)
            guard b - t > 0.05 else { return nil }
            return Band(category: category, rect: CGRect(x: 0, y: t, width: 1, height: b - t))
        }

        var bands: [Band] = []
        if let top = band(.top, shoulders - 0.15 * torso, hips + 0.22 * torso) { bands.append(top) }
        let legsEnd = ankles.map { $0 + 0.02 } ?? 1
        if let bottom = band(.bottom, hips - 0.2 * torso, legsEnd) { bands.append(bottom) }
        if let ankles, let shoes = band(.shoes, ankles - 0.04, 1) { bands.append(shoes) }
        // One band is a portrait, not an outfit to split.
        return bands.count >= 2 ? bands : []
    }

    // MARK: - Rendering

    /// Masks the photo, crops to the garment and frames it with even padding.
    private static func render(_ input: CIImage, mask rawMask: CIImage, normalizedBox: CGRect,
                               band: CGRect?, size: CGSize) -> UIImage? {
        var mask = rawMask
        if mask.extent.size != input.extent.size {
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: input.extent.width / mask.extent.width,
                y: input.extent.height / mask.extent.height
            ))
        }
        if let band {
            let ciBand = ciRect(band, size: size)
            let black = CIImage(color: .black).cropped(to: input.extent)
            mask = mask.cropped(to: ciBand).composited(over: black)
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = input
        blend.backgroundImage = CIImage(color: .clear).cropped(to: input.extent)
        blend.maskImage = mask
        guard let output = blend.outputImage else { return nil }

        let padded = normalizedBox.insetBy(dx: -0.01, dy: -0.01)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let crop = ciRect(padded, size: size).integral.intersection(input.extent)
        guard !crop.isEmpty,
              let cg = ciContext.createCGImage(output, from: crop, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        return framed(UIImage(cgImage: cg))
    }

    /// Even transparent margin around the garment (the "studio" look).
    private static func framed(_ image: UIImage) -> UIImage {
        let margin = max(image.size.width, image.size.height) * 0.06
        let canvas = CGSize(width: image.size.width + margin * 2, height: image.size.height + margin * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            image.draw(in: CGRect(x: margin, y: margin, width: image.size.width, height: image.size.height))
        }
    }

    private static func ciRect(_ normalized: CGRect, size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width,
               y: (1 - normalized.maxY) * size.height,
               width: normalized.width * size.width,
               height: normalized.height * size.height)
    }

    private static func meanLuminance(_ image: CIImage) -> Double {
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = image.extent
        guard let output = average.outputImage else { return 1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
    }

    /// Orientation-correct, bounded-size bitmap so masks and pose share coordinates.
    private static func normalizedCGImage(_ image: UIImage) -> CGImage? {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > 0 else { return nil }
        let scale = min(1, maxSide / longSide)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}

// MARK: - Instance statistics (low-res label mask)

private struct InstanceStats {
    private var pixelCount: [Int: Int] = [:]
    private var borderCount: [Int: Int] = [:]
    private var minX: [Int: Int] = [:], minY: [Int: Int] = [:]
    private var maxX: [Int: Int] = [:], maxY: [Int: Int] = [:]
    private let width: Int
    private let height: Int

    init?(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 2, height > 2 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                let label = Int(row[x])
                guard label > 0 else { continue }
                pixelCount[label, default: 0] += 1
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 {
                    borderCount[label, default: 0] += 1
                }
                minX[label] = min(minX[label] ?? x, x)
                maxX[label] = max(maxX[label] ?? x, x)
                minY[label] = min(minY[label] ?? y, y)
                maxY[label] = max(maxY[label] ?? y, y)
            }
        }
        guard !pixelCount.isEmpty else { return nil }
    }

    /// Instances worth keeping, largest first.
    func mainInstances(clutterRatio: Double) -> [Int] {
        let sorted = pixelCount.sorted { $0.value > $1.value }
        guard let largest = sorted.first?.value else { return [] }
        return sorted.filter { Double($0.value) >= Double(largest) * clutterRatio }.map(\.key)
    }

    func coverage(of set: IndexSet) -> Double {
        Double(set.reduce(0) { $0 + (pixelCount[$1] ?? 0) }) / Double(width * height)
    }

    /// Share of the photo's border pixels the garment touches.
    func borderShare(of set: IndexSet) -> Double {
        let perimeter = 2 * (width + height) - 4
        return Double(set.reduce(0) { $0 + (borderCount[$1] ?? 0) }) / Double(perimeter)
    }

    /// Normalized, top-left origin.
    func boundingBox(of set: IndexSet) -> CGRect {
        let labels = set.filter { pixelCount[$0] != nil }
        guard !labels.isEmpty else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let x0 = labels.compactMap { minX[$0] }.min() ?? 0
        let x1 = labels.compactMap { maxX[$0] }.max() ?? width - 1
        let y0 = labels.compactMap { minY[$0] }.min() ?? 0
        let y1 = labels.compactMap { maxY[$0] }.max() ?? height - 1
        return CGRect(x: CGFloat(x0) / CGFloat(width), y: CGFloat(y0) / CGFloat(height),
                      width: CGFloat(x1 - x0 + 1) / CGFloat(width),
                      height: CGFloat(y1 - y0 + 1) / CGFloat(height))
    }
}
