//
//  ImageCropperView.swift
//  WearIt
//
//  Lightweight crop UI with zoom/drag and a square overlay.
//

import SwiftUI
import Vision

struct ImageCropperView: View {
    enum Aspect: String, CaseIterable, Identifiable {
        case square, portrait34, landscape43, free
        var id: String { rawValue }
        var title: String {
            switch self {
            case .square: return "1:1"
            case .portrait34: return "3:4"
            case .landscape43: return "4:3"
            case .free: return "Free"
            }
        }
        func ratio() -> CGSize? {
            switch self {
            case .square: return CGSize(width: 1, height: 1)
            case .portrait34: return CGSize(width: 3, height: 4)
            case .landscape43: return CGSize(width: 4, height: 3)
            case .free: return nil
            }
        }
    }

    let image: UIImage
    var initialAspect: Aspect = .portrait34
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    /// Upright pixels — display and crop share the same coordinate space.
    @State private var source: UIImage
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var aspect: Aspect = .portrait34
    @State private var isAutoFitting = false

    init(
        image: UIImage,
        initialAspect: Aspect = .portrait34,
        onCancel: @escaping () -> Void,
        onDone: @escaping (UIImage) -> Void
    ) {
        self.image = image
        self.initialAspect = initialAspect
        self.onCancel = onCancel
        self.onDone = onDone
        _source = State(initialValue: image.fixOrientation())
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                imageView(in: geo.size)
                    .overlay(cropOverlay(in: geo.size))

                VStack {
                    topBar(in: geo.size)
                    Spacer()
                    aspectBar
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 16)
            }
        }
        // Image pan/crop math is absolute; don't mirror under Hebrew RTL.
        .environment(\.layoutDirection, .leftToRight)
        .onAppear {
            aspect = initialAspect
            source = image.fixOrientation()
        }
    }

    private func topBar(in container: CGSize) -> some View {
        HStack {
            Button(String(localized: "crop_cancel"), action: onCancel)
                .foregroundStyle(.white)
            Spacer()
            Button(isAutoFitting ? String(localized: "crop_auto_busy") : String(localized: "crop_auto")) {
                Task { await autoFit(in: container) }
            }
            .foregroundStyle(.white.opacity(0.9))
            .disabled(isAutoFitting)
            Spacer()
            Button(String(localized: "crop_done")) {
                if let cropped = crop(in: container) {
                    onDone(cropped)
                } else {
                    onCancel()
                }
            }
            .bold()
            .foregroundStyle(.white)
        }
        .padding(.top, 16)
    }

    private var aspectBar: some View {
        HStack(spacing: 8) {
            ForEach(Aspect.allCases) { a in
                Button {
                    withAnimation(DS.Animation.fast) {
                        aspect = a
                    }
                } label: {
                    Text(a.title)
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(a == aspect ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
                        .overlay(
                            Capsule().stroke(Color.white.opacity(a == aspect ? 0.9 : 0.3), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            Button(String(localized: "crop_reset")) { reset() }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.leading, 6)
        }
        .padding(10)
        .liquidGlassPill()
    }

    private func imageView(in container: CGSize) -> some View {
        Image(uiImage: source)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: container.width, height: container.height)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                SimultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        },
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(max(0.8, lastScale * value), 4.0)
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                )
            )
    }

    private func cropOverlay(in container: CGSize) -> some View {
        let rect = cropRect(in: container)
        return ZStack {
            Color.black.opacity(0.45)
                .mask(
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: container))
                        p.addRoundedRect(in: rect,
                                         cornerSize: CGSize(width: 18, height: 18),
                                         style: .continuous)
                    }
                    .fill(style: FillStyle(eoFill: true))
                )

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .allowsHitTesting(false)
    }

    private func cropRect(in container: CGSize) -> CGRect {
        let padding: CGFloat = 0.12
        let availableWidth = container.width * (1 - padding * 2)
        let availableHeight = container.height * (1 - padding * 2)

        let ratio = aspect.ratio()
        let size: CGSize
        if let ratio {
            let w1 = availableWidth
            let h1 = w1 * ratio.height / ratio.width
            if h1 <= availableHeight {
                size = CGSize(width: w1, height: h1)
            } else {
                let h2 = availableHeight
                let w2 = h2 * ratio.width / ratio.height
                size = CGSize(width: w2, height: h2)
            }
        } else {
            size = CGSize(width: availableWidth, height: availableHeight)
        }

        let origin = CGPoint(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2
        )
        return CGRect(origin: origin, size: size)
    }

    /// Display scale of the image inside the container (aspect-fit × user zoom).
    private func displayScale(in container: CGSize) -> CGFloat {
        let fit = min(container.width / source.size.width, container.height / source.size.height)
        return fit * scale
    }

    /// Top-left of the scaled image in container coordinates.
    private func imageOrigin(in container: CGSize) -> CGPoint {
        let ds = displayScale(in: container)
        let displayed = CGSize(
            width: source.size.width * ds,
            height: source.size.height * ds
        )
        return CGPoint(
            x: (container.width - displayed.width) / 2 + offset.width,
            y: (container.height - displayed.height) / 2 + offset.height
        )
    }

    private func crop(in container: CGSize) -> UIImage? {
        let cropRectScreen = cropRect(in: container)
        let ds = displayScale(in: container)
        guard ds > 0 else { return source }

        let origin = imageOrigin(in: container)
        let rectInImage = CGRect(
            x: (cropRectScreen.minX - origin.x) / ds,
            y: (cropRectScreen.minY - origin.y) / ds,
            width: cropRectScreen.width / ds,
            height: cropRectScreen.height / ds
        )

        let bounds = CGRect(origin: .zero, size: source.size)
        let clipped = rectInImage.intersection(bounds)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else {
            return source
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = source.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: clipped.size, format: format)
        return renderer.image { _ in
            source.draw(at: CGPoint(x: -clipped.origin.x, y: -clipped.origin.y))
        }
    }

    private func reset() {
        withAnimation(DS.Animation.standard) {
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            lastOffset = .zero
            aspect = .square
        }
    }

    // MARK: - Auto detect garment area (best effort using rectangles)
    private func autoFit(in container: CGSize) async {
        isAutoFitting = true
        defer { isAutoFitting = false }

        guard let cgImage = source.cgImage else { return }
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.1
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let rect = request.results?.first?.boundingBox else { return }

        let imgSize = source.size
        let detected = CGRect(
            x: rect.minX * imgSize.width,
            y: (1 - rect.maxY) * imgSize.height,
            width: rect.width * imgSize.width,
            height: rect.height * imgSize.height
        )

        let cropRectScreen = cropRect(in: container)
        let fitBase = min(container.width / imgSize.width, container.height / imgSize.height)
        let scaleNeeded = min(
            cropRectScreen.width / max(detected.width, 1),
            cropRectScreen.height / max(detected.height, 1)
        )
        // scaleNeeded is in screen-px per image-px relative to unzoomed fit;
        // convert to the user `scale` multiplier on top of aspect-fit.
        let appliedScale = max(0.8, min(4.0, scaleNeeded / fitBase))

        // Place detected center under crop-frame center.
        let detectedCenter = CGPoint(x: detected.midX, y: detected.midY)
        let imageCenter = CGPoint(x: imgSize.width / 2, y: imgSize.height / 2)
        let deltaImage = CGPoint(
            x: detectedCenter.x - imageCenter.x,
            y: detectedCenter.y - imageCenter.y
        )
        // After zoom, 1 image point = fitBase * appliedScale screen points.
        let screenPerImage = fitBase * appliedScale
        let targetOffset = CGSize(
            width: -deltaImage.x * screenPerImage,
            height: -deltaImage.y * screenPerImage
        )

        withAnimation(DS.Animation.standard) {
            scale = appliedScale
            lastScale = appliedScale
            offset = targetOffset
            lastOffset = targetOffset
        }
    }
}
