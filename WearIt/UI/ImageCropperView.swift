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
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var aspect: Aspect = .square
    @State private var isAutoFitting = false

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
    }

    private func topBar(in container: CGSize) -> some View {
        HStack {
            Button("Cancel", action: onCancel)
                .foregroundStyle(.white)
            Spacer()
            Button(isAutoFitting ? "Auto…" : "Auto") {
                Task { await autoFit(in: container) }
            }
            .foregroundStyle(.white.opacity(0.9))
            .disabled(isAutoFitting)
            Spacer()
            Button("Done") {
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
                    withAnimation(.spring(duration: 0.25)) {
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
            Button("Reset") { reset() }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.leading, 6)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private func imageView(in container: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: container.width, height: container.height)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(0.8, lastScale * value), 4.0)
                    }
                    .onEnded { _ in
                        lastScale = scale
                    }
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
        let availableWidth = container.width * (1 - padding*2)
        let availableHeight = container.height * (1 - padding*2)

        let ratio = aspect.ratio()
        let size: CGSize
        if let ratio {
            // Fit within available while keeping aspect
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

        let origin = CGPoint(x: (container.width - size.width)/2,
                             y: (container.height - size.height)/2)
        return CGRect(origin: origin, size: size)
    }

    private func crop(in container: CGSize) -> UIImage? {
        let cropRectScreen = cropRect(in: container)

        let imageScale: CGFloat = {
            let imgSize = image.size
            let scaleW = container.width / imgSize.width
            let scaleH = container.height / imgSize.height
            return min(scaleW, scaleH) * scale
        }()

        let imgCenter = CGPoint(x: container.width / 2 + offset.width,
                                y: container.height / 2 + offset.height)

        let originX = (cropRectScreen.minX - (imgCenter.x - (image.size.width * imageScale) / 2)) / imageScale
        let originY = (cropRectScreen.minY - (imgCenter.y - (image.size.height * imageScale) / 2)) / imageScale
        let cropRectImage = CGRect(
            x: originX,
            y: originY,
            width: cropRectScreen.width / imageScale,
            height: cropRectScreen.height / imageScale
        ).integral

        guard let cg = image.cgImage,
              let cropped = cg.cropping(to: cropRectImage.intersection(CGRect(origin: .zero, size: image.size))) else {
            // אם החיתוך נכשל – מחזירים את המקור כדי לא לאבד תמונה
            return image
        }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private func reset() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
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

        guard let cgImage = image.cgImage else { return }
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.1
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let rect = request.results?.first?.boundingBox else { return }

        // Vision rect is normalized; convert to image space
        let imgSize = image.size
        let detected = CGRect(
            x: rect.minX * imgSize.width,
            y: (1 - rect.maxY) * imgSize.height,
            width: rect.width * imgSize.width,
            height: rect.height * imgSize.height
        )

        // Fit detected rect into current crop frame by adjusting offset/scale
        let cropRectScreen = cropRect(in: container)
        let scaleNeededW = cropRectScreen.width / detected.width
        let scaleNeededH = cropRectScreen.height / detected.height
        let targetScale = min(scaleNeededW, scaleNeededH)

        let imgScaleBase: CGFloat = {
            let scaleW = container.width / imgSize.width
            let scaleH = container.height / imgSize.height
            return min(scaleW, scaleH)
        }()

        let appliedScale = max(0.8, min(4.0, targetScale * imgScaleBase))

        // Target center of detected box in screen coords
        let imgCenterScreen = CGPoint(x: container.width/2 + offset.width,
                                      y: container.height/2 + offset.height)
        let detectedCenterImage = CGPoint(x: detected.midX, y: detected.midY)
        let targetCenterScreen = CGPoint(
            x: container.width/2 - (detectedCenterImage.x - imgSize.width/2) * imgScaleBase,
            y: container.height/2 - (detectedCenterImage.y - imgSize.height/2) * imgScaleBase
        )

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            scale = appliedScale
            lastScale = appliedScale
            let dx = targetCenterScreen.x - imgCenterScreen.x
            let dy = targetCenterScreen.y - imgCenterScreen.y
            offset = CGSize(width: offset.width + dx, height: offset.height + dy)
            lastOffset = offset
        }
    }
}

