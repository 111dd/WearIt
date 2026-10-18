import SwiftUI
import VisionKit
import UIKit
import Observation

enum GarmentPhotoTool: String, Identifiable {
    case subject, findPhoto
    var id: String { rawValue }
}

/// Native subject lifting, with garment/body-band choices when Apple identifies
/// an entire person instead of an individual piece of clothing.
struct GarmentSubjectPicker: View {
    var imagePath: String? = nil
    var fallbackImagePath: String? = nil
    var legacyData: Data? = nil
    var image: UIImage? = nil
    let category: Category
    let onUse: (UIImage, UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection = GarmentSubjectSelection()

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.sm) {
                Text(String(localized: "photo_subject_instructions"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal)
                if let source = selection.source {
                    NativeGarmentSubjectImage(image: source, selection: selection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                        .padding(.horizontal, DS.Spacing.md)
                }
                if selection.isPreparing { ProgressView(String(localized: "photo_subject_analyzing")) }
                if !selection.candidates.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: DS.Spacing.sm) {
                            ForEach(selection.candidates) { candidate in
                                Button {
                                    selection.selected = candidate.image
                                    selection.interaction.highlightedSubjects = []
                                    selection.message = nil
                                } label: {
                                    VStack(spacing: 4) {
                                        GarmentPhotoCanvas(image: candidate.image)
                                            .frame(width: 82, height: 82)
                                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile))
                                        Text(candidate.title).font(.caption)
                                    }
                                    .foregroundStyle(.primary)
                                }.buttonStyle(.plain).disabled(selection.isExtracting)
                            }
                        }.padding(.horizontal, DS.Spacing.md)
                    }.scrollIndicators(.hidden)
                }
                if let preview = selection.selected {
                    HStack(spacing: DS.Spacing.sm) {
                        GarmentPhotoCanvas(image: preview).frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile))
                        Text(String(localized: "photo_subject_selection_ready")).font(.caption)
                        Spacer()
                    }.padding(.horizontal, DS.Spacing.md)
                }
                if let message = selection.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                Button {
                    selection.useSelection { cutout, original in
                        onUse(cutout, image ?? original)
                        dismiss()
                    }
                } label: {
                    Text(String(localized: "photo_subject_use_selection")).frame(maxWidth: .infinity)
                }
                .dsPrimaryButton()
                .disabled(selection.source == nil || selection.isPreparing || selection.isExtracting)
                .padding(DS.Spacing.md)
            }
            .navigationTitle(String(localized: "photo_tool_select_subject"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
            }
            .withLocalAppBackdropPainted()
        }
        .task {
            let path = imagePath, fallback = fallbackImagePath, data = legacyData, supplied = image
            let loaded = await Task.detached(priority: .userInitiated) {
                if let supplied { return GarmentPhotoFraming.workingImage(supplied) }
                if let path, let photo = ImageStore.loadThumbnail(path: path, maxPixelSize: 2400) { return photo }
                if let fallback, let photo = ImageStore.loadThumbnail(path: fallback, maxPixelSize: 2400) { return photo }
                return data.flatMap { ImageStore.downsample(data: $0, maxPixelSize: 2400) }!
            }.value
            guard !Task.isCancelled else { return }
            await selection.prepare(loaded, category: category)
        }
        .onDisappear { selection.stop() }
    }
}

@MainActor
@Observable private final class GarmentSubjectSelection {
    var source: UIImage?
    var selected: UIImage?
    var candidates: [CutoutCandidate] = []
    var isPreparing = true
    var isExtracting = false
    var message: String?
    let interaction = ImageAnalysisInteraction()
    private let analyzer = ImageAnalyzer()
    @ObservationIgnored private var extraction: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func prepare(_ image: UIImage?, category: Category) async {
        guard let image else {
            isPreparing = false
            message = String(localized: "edit_image_save_failed")
            return
        }
        source = image
        interaction.preferredInteractionTypes = [.imageSubject]
        // Subject lifting is an interaction type; AnalysisTypes has no imageSubject case.
        if ImageAnalyzer.isSupported {
            let analysis = try? await analyzer.analyze(image, configuration: .init([.text]))
            guard !Task.isCancelled else { return }
            interaction.analysis = analysis
            if analysis != nil { isPreparing = false }
        }
        let choices = await Task.detached(priority: .utility) {
            GarmentCutoutService.analyze(image, preferredCategory: category)?.candidates ?? []
        }.value
        guard !Task.isCancelled else { return }
        candidates = choices
        isPreparing = false
        if interaction.analysis == nil, choices.isEmpty {
            message = String(localized: "photo_subject_no_selection")
        }
    }

    func tapped(at point: CGPoint) {
        guard !isPreparing, !isExtracting else { return }
        extraction?.cancel()
        generation = UUID()
        let token = generation
        extraction = Task {
            let subject = await interaction.subject(at: point)
            guard !Task.isCancelled, token == generation else { return }
            guard let subject else {
                selected = nil
                interaction.highlightedSubjects = []
                return
            }
            interaction.highlightedSubjects = [subject]
            let cutout = try? await interaction.image(for: [subject])
            guard !Task.isCancelled, token == generation else { return }
            selected = cutout
            message = nil
        }
    }

    func useSelection(_ onUse: @escaping (UIImage, UIImage) -> Void) {
        guard let source else { return }
        extraction?.cancel()
        generation = UUID()
        let token = generation
        isExtracting = true
        extraction = Task {
            var result = selected
            // Also honor selection made by Apple's native long-press interaction.
            if !interaction.highlightedSubjects.isEmpty {
                result = try? await interaction.image(for: interaction.highlightedSubjects)
            }
            guard !Task.isCancelled, token == generation else { return }
            isExtracting = false
            guard let result else {
                message = String(localized: "photo_subject_no_selection")
                return
            }
            onUse(result, source)
        }
    }

    func stop() { generation = UUID(); extraction?.cancel(); extraction = nil }
}

private struct NativeGarmentSubjectImage: UIViewRepresentable {
    let image: UIImage
    let selection: GarmentSubjectSelection

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        view.addInteraction(selection.interaction)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        view.accessibilityLabel = String(localized: "photo_subject_instructions")
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(selection: selection) }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: Coordinator) {
        coordinator.selection.stop()
        for interaction in uiView.interactions { uiView.removeInteraction(interaction) }
    }

    @MainActor final class Coordinator: NSObject {
        let selection: GarmentSubjectSelection
        init(selection: GarmentSubjectSelection) { self.selection = selection }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            selection.tapped(at: gesture.location(in: gesture.view))
        }
    }
}
