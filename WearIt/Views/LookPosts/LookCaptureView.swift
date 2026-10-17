import SwiftUI
import SwiftData
import PhotosUI

/// "Snap the look": take or pick a photo of the look worn that day, frame it 4:5
/// around the person, optionally hide the face or blur the background, add a
/// caption, and save it as a private post on the profile grid.
/// Everything runs on device; the saved JPEG has no location or camera details.
struct LookCaptureView: View {
    let lookDate: Date
    var isEvening: Bool = false
    /// Worn items; nil reads them from that day's plan.
    var garmentIDs: [UUID]? = nil
    var onSaved: ((LookPost) -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showCamera = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var analysis: LookPhotoProcessor.Analysis?
    @State private var preview: UIImage?
    @State private var options = LookPhotoProcessor.Options()
    @State private var caption = ""
    @State private var isWorking = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var renderTask: Task<Void, Never>?

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.md) {
                    if let preview {
                        editor(preview)
                    } else {
                        sourceChooser
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(String(localized: isEvening ? "look_capture_title_evening" : "look_capture_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
                if preview != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "look_capture_save")) { save() }
                            .fontWeight(.semibold)
                            .disabled(isWorking || isSaving)
                    }
                }
            }
            .withLocalAppBackdrop()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPickerWrapper { image in load(image) }
                .ignoresSafeArea()
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            libraryItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    errorMessage = String(localized: "error_save_failed")
                    return
                }
                load(image)
            }
        }
        .onChange(of: options) { _, _ in rerender() }
        .onDisappear { renderTask?.cancel() }
    }

    // MARK: - Source

    private var sourceChooser: some View {
        VStack(spacing: DS.Spacing.lg) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.top, DS.Spacing.xl)

            VStack(spacing: DS.Spacing.xs) {
                Text(String(localized: "look_capture_headline"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(String(localized: "look_capture_subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: DS.Spacing.sm) {
                if cameraAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label(String(localized: "garment_take_photo"), systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .dsPrimaryButton()
                }
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    Label(String(localized: "garment_choose_library"), systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .dsSecondaryButton()
            }
            .padding(.horizontal, DS.Spacing.lg)

            if isWorking {
                ProgressView()
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            privacyNote
        }
    }

    // MARK: - Editor

    private func editor(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay {
                    if isWorking {
                        ProgressView()
                            .padding(DS.Spacing.sm)
                            .liquidGlassCircle()
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(String(localized: "look_capture_preview_a11y")))

            HStack(spacing: DS.Spacing.xs) {
                optionChip(
                    title: String(localized: "look_capture_hide_face"),
                    icon: "face.dashed",
                    isOn: $options.hideFace,
                    available: analysis?.hasFace ?? false
                )
                optionChip(
                    title: String(localized: "look_capture_blur_background"),
                    icon: "person.and.background.dotted",
                    isOn: $options.blurBackground,
                    available: analysis?.hasPerson ?? false
                )
                Spacer(minLength: 0)
                Button {
                    reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .liquidGlassCircle(interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "look_capture_retake")))
            }

            if let analysis, !analysis.hasFace, !analysis.hasPerson {
                Text(String(localized: "look_capture_no_person"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField(String(localized: "look_capture_caption_placeholder"), text: $caption, axis: .vertical)
                .lineLimit(1...3)
                .dsFieldStyle()

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            privacyNote
        }
    }

    private func optionChip(title: String, icon: String, isOn: Binding<Bool>, available: Bool) -> some View {
        Button {
            DS.haptic(0.3)
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
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private var privacyNote: some View {
        Label(String(localized: "look_capture_privacy_note"), systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Work

    private func load(_ image: UIImage) {
        errorMessage = nil
        isWorking = true
        let current = options
        renderTask?.cancel()
        renderTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (LookPhotoProcessor.Analysis, UIImage)? in
                guard let analysis = LookPhotoProcessor.analyze(image),
                      let rendered = LookPhotoProcessor.render(analysis, options: current) else { return nil }
                return (analysis, rendered)
            }.value
            guard !Task.isCancelled else { return }
            isWorking = false
            guard let result else {
                errorMessage = String(localized: "error_save_failed")
                return
            }
            withAnimation(reduceMotion ? nil : DS.Animation.standard) {
                analysis = result.0
                preview = result.1
            }
        }
    }

    private func rerender() {
        guard let analysis else { return }
        let current = options
        isWorking = true
        renderTask?.cancel()
        renderTask = Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                LookPhotoProcessor.render(analysis, options: current)
            }.value
            guard !Task.isCancelled else { return }
            isWorking = false
            if let rendered { preview = rendered }
        }
    }

    private func reset() {
        renderTask?.cancel()
        isWorking = false
        analysis = nil
        preview = nil
        options = LookPhotoProcessor.Options()
    }

    private func save() {
        guard let preview, !isSaving else { return }
        isSaving = true
        let chosen = options
        Task {
            let jpeg = await Task.detached(priority: .userInitiated) {
                LookPhotoProcessor.jpegData(preview)
            }.value
            guard let jpeg,
                  let post = try? LookPostStore.create(
                    jpeg: jpeg,
                    lookDate: lookDate,
                    isEvening: isEvening,
                    garmentIDs: garmentIDs,
                    caption: caption,
                    options: chosen,
                    context: context
                  ) else {
                isSaving = false
                errorMessage = String(localized: "error_save_failed")
                return
            }
            DS.haptic(0.6)
            onSaved?(post)
            dismiss()
        }
    }
}
