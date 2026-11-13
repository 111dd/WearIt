import SwiftUI
import UIKit

/// Face and background blur for a wardrobe photo, using the same on-device treatment as a daily look.
struct GarmentPhotoPolishView: View {
    let garment: Garment
    let onUse: (UIImage, UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: UIImage?
    @State private var analysis: LookPhotoProcessor.Analysis?
    @State private var preview: UIImage?
    @State private var options = LookPhotoProcessor.Options()
    @State private var isWorking = true
    @State private var message: String?
    @State private var renderID = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    Text(String(localized: "photo_polish_explanation"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    GarmentPhotoCanvas(image: preview ?? source)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay { if isWorking { ProgressView() } }
                    HStack(spacing: DS.Spacing.xs) {
                        optionChip(String(localized: "look_capture_hide_face"), icon: "face.dashed",
                                   isOn: $options.hideFace, available: analysis?.hasFace == true)
                        optionChip(String(localized: "look_capture_blur_background"), icon: "person.and.background.dotted",
                                   isOn: $options.blurBackground, available: analysis?.hasPerson == true)
                    }
                    if let analysis, !analysis.hasFace, !analysis.hasPerson {
                        Text(String(localized: "photo_polish_no_person"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Button(String(localized: "photo_polish_save")) { save() }
                        .dsPrimaryButton()
                        .disabled(preview == nil || isWorking || (!options.hideFace && !options.blurBackground))
                }
                .padding(DS.Spacing.md)
            }
            .navigationTitle(String(localized: "photo_tool_polish"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
            }
            .withLocalAppBackdropPainted()
        }
        .task { await load() }
        .onChange(of: options) { _, _ in rerender() }
    }

    private func optionChip(_ title: String, icon: String, isOn: Binding<Bool>, available: Bool) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, DS.Spacing.sm)
                .frame(height: 40)
                .foregroundStyle(isOn.wrappedValue ? DS.Accent.onFill : Color.primary)
                .liquidGlassPill(interactive: true, tint: isOn.wrappedValue ? Color.accentColor : nil)
        }
        .buttonStyle(.plain)
        .disabled(!available || isWorking)
        .opacity(available ? 1 : 0.45)
    }

    @MainActor private func load() async {
        let path = garment.originalImagePath ?? garment.imagePath
        let data = garment.imageData
        let image = await Task.detached(priority: .userInitiated) {
            path.flatMap { ImageStore.loadThumbnail(path: $0, maxPixelSize: 2400) }
                ?? data.flatMap { ImageStore.downsample(data: $0, maxPixelSize: 2400) }
        }.value
        guard !Task.isCancelled else { return }
        source = image
        guard let image else {
            isWorking = false
            message = String(localized: "photo_polish_no_photo")
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> (LookPhotoProcessor.Analysis, UIImage)? in
            guard let analysis = LookPhotoProcessor.analyze(image) else { return nil }
            return (analysis, LookPhotoProcessor.renderEdited(analysis, options: LookPhotoProcessor.Options()) ?? image)
        }.value
        guard !Task.isCancelled else { return }
        isWorking = false
        guard let result else {
            message = String(localized: "photo_polish_no_person")
            preview = image
            return
        }
        analysis = result.0
        preview = result.1
    }

    private func rerender() {
        guard let analysis else { return }
        let current = options
        renderID += 1
        let id = renderID
        isWorking = true
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                LookPhotoProcessor.renderEdited(analysis, options: current)
            }.value
            guard !Task.isCancelled, id == renderID else { return }
            isWorking = false
            if let rendered { preview = rendered }
        }
    }

    private func save() {
        guard let preview, let source, options.hideFace || options.blurBackground else { return }
        onUse(preview, source)
        dismiss()
    }
}
