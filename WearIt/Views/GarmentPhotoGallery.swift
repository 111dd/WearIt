import SwiftUI
import UIKit

struct GarmentGallerySelection: Identifiable {
    let id: String
}

struct GarmentPhotoGallery: View {
    let garment: Garment
    let isBusy: Bool
    let onOpen: (String) -> Void
    let onMakePrimary: (String) -> Void
    let onRoleChange: (String, GarmentPhotoRole) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(String(localized: "garment_photo_gallery_title"))
                .font(.subheadline.weight(.semibold))
            Text(String(localized: "garment_photo_gallery_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    ForEach(garment.galleryPhotoPaths, id: \.self) { path in
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Button { onOpen(path) } label: {
                                GarmentGalleryImage(path: path, maxPixel: 300)
                                    .frame(width: 104, height: 112)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile))
                                    .overlay(alignment: .topLeading) {
                                        if path == garment.imagePath {
                                            Image(systemName: "star.fill")
                                                .font(.caption.weight(.semibold))
                                                .padding(6)
                                                .background(.regularMaterial, in: Circle())
                                                .padding(4)
                                                .accessibilityHidden(true)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(path == garment.imagePath
                                ? String(localized: "garment_photo_primary") : garment.photoInfo(for: path).role.title)
                            .accessibilityHint(String(localized: "garment_photo_open_hint"))

                            Text(path == garment.imagePath
                                ? String(localized: "garment_photo_primary")
                                : String(localized: "garment_photo_additional"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            GarmentPhotoMenu(
                                garment: garment, path: path,
                                onMakePrimary: { onMakePrimary(path) },
                                onRoleChange: { onRoleChange(path, $0) },
                                onRemove: { onRemove(path) }
                            )
                            .disabled(isBusy)
                        }
                        .frame(width: 104, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct GarmentPhotoMenu: View {
    let garment: Garment
    let path: String
    let onMakePrimary: () -> Void
    let onRoleChange: (GarmentPhotoRole) -> Void
    let onRemove: () -> Void

    var body: some View {
        let selectedRole = garment.photoInfo(for: path).role
        Menu {
            if path != garment.imagePath {
                Button(action: onMakePrimary) {
                    Label(String(localized: "garment_photo_make_primary"), systemImage: "star")
                }
            }
            Section(String(localized: "garment_photo_role_title")) {
                ForEach(GarmentPhotoRole.choices(category: garment.category, itemType: garment.itemType)) { role in
                    Button { onRoleChange(role) } label: {
                        if selectedRole == role {
                            Label(role.title, systemImage: "checkmark")
                        } else {
                            Text(role.title)
                        }
                    }
                }
            }
            Button(role: .destructive, action: onRemove) {
                Label(String(localized: "action_remove_photo"), systemImage: "trash")
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(selectedRole.title)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "garment_photo_actions"))
        .accessibilityValue(selectedRole.title)
    }
}

struct GarmentPhotoViewer: View {
    let garment: Garment
    @Binding var isBusy: Bool
    @Binding var errorMessage: String?
    let onMakePrimary: (String) -> Void
    let onRoleChange: (String, GarmentPhotoRole) -> Void
    let onRemove: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String

    init(
        garment: Garment, startPath: String, isBusy: Binding<Bool>, errorMessage: Binding<String?>,
        onMakePrimary: @escaping (String) -> Void,
        onRoleChange: @escaping (String, GarmentPhotoRole) -> Void,
        onRemove: @escaping (String) -> Void
    ) {
        self.garment = garment
        _selection = State(initialValue: startPath)
        _isBusy = isBusy
        _errorMessage = errorMessage
        self.onMakePrimary = onMakePrimary
        self.onRoleChange = onRoleChange
        self.onRemove = onRemove
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(garment.galleryPhotoPaths, id: \.self) { path in
                    GarmentGalleryImage(path: path, maxPixel: 2200)
                        .padding()
                        .tag(path)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .background(Color(.systemBackground))
            .navigationTitle(selection == garment.imagePath
                ? String(localized: "garment_photo_primary") : garment.photoInfo(for: selection).role.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action_done")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: DS.Spacing.md) {
                    if isBusy { ProgressView() }
                    if garment.galleryPhotoPaths.contains(selection) {
                        if selection != garment.imagePath {
                            Button {
                                onMakePrimary(selection)
                            } label: {
                                Label(String(localized: "garment_photo_make_primary"), systemImage: "star")
                            }
                            .disabled(isBusy)
                        }
                        Spacer(minLength: 0)
                        GarmentPhotoMenu(
                            garment: garment, path: selection,
                            onMakePrimary: { onMakePrimary(selection) },
                            onRoleChange: { onRoleChange(selection, $0) },
                            onRemove: { onRemove(selection) }
                        )
                        .disabled(isBusy)
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
            .onChange(of: garment.galleryPhotoPaths) { _, paths in
                if paths.isEmpty {
                    dismiss()
                } else if !paths.contains(selection), let first = paths.first {
                    selection = first
                }
            }
            .alert(String(localized: "error_title"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(String(localized: "action_confirm"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? String(localized: "error_generic"))
            }
        }
    }
}

/// Downsample every gallery image, including full-screen pages, off the UI actor.
private struct GarmentGalleryImage: View {
    let path: String
    let maxPixel: CGFloat
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                VStack(spacing: DS.Spacing.xxs) {
                    Image(systemName: "photo")
                    Text(String(localized: "garment_photo_unavailable"))
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: path) {
            image = nil
            failed = false
            let imagePath = path
            let pixelSize = maxPixel
            let loaded = await Task.detached(priority: .utility) {
                ImageStore.loadThumbnail(path: imagePath, maxPixelSize: pixelSize)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}
