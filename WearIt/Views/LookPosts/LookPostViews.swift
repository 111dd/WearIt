import SwiftUI
import SwiftData

// MARK: - Grid

/// The profile's photo grid: 3 columns of 4:5 look photos, pinned first.
/// Tapping a photo zooms into its post.
struct LookPostGridSection: View {
    let posts: [LookPost]
    let namespace: Namespace.ID
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                DSSectionHeader(String(localized: "profile_my_looks"), icon: "photo.stack")
                if !posts.isEmpty {
                    Text("\(posts.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onAdd) {
                    Image(systemName: "camera")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .liquidGlassCircle(interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "look_capture_title")))
            }

            if posts.isEmpty {
                emptyState
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                    spacing: 2
                ) {
                    ForEach(posts) { post in
                        NavigationLink {
                            LookPostDetailView(post: post)
                                .navigationTransition(.zoom(sourceID: post.id, in: namespace))
                        } label: {
                            LookPostThumbnail(post: post)
                                .matchedTransitionSource(id: post.id, in: namespace)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            }
        }
        .padding(DS.Spacing.sm)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.sm) {
            Text(String(localized: "profile_looks_empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onAdd) {
                Label(String(localized: "look_capture_cta"), systemImage: "camera")
            }
            .dsSecondaryButton()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.md)
    }
}

/// One 4:5 grid cell. Loads a downsampled copy off the main thread.
struct LookPostThumbnail: View {
    let post: LookPost
    @State private var image: UIImage?

    var body: some View {
        Color(.systemGray6)
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if post.isPinned {
                    badge("pin.fill")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if post.isEvening {
                    badge("moon.stars.fill")
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(Text(LookPostDetailView.dateTitle(for: post)))
            .accessibilityAddTraits(.isButton)
            .task(id: post.photoPath) { await load() }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .padding(6)
    }

    private func load() async {
        guard let path = LookPostStore.localPhotoPath(for: post) else { return }
        let maxPixel = 400 * UIScreen.main.scale
        let loaded = await Task.detached(priority: .utility) {
            ImageStore.loadThumbnail(path: path, maxPixelSize: maxPixel)
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

// MARK: - Post

/// One look post: the photo, its day, caption, and the items worn. Item tags are
/// private; "Show tag" marks the ones the user is happy to show once sharing exists.
struct LookPostDetailView: View {
    @Bindable var post: LookPost

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var garments: [Garment] = []
    @State private var captionDraft = ""
    @State private var isEditingCaption = false
    @State private var confirmDelete = false
    @FocusState private var captionFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                photo
                metaRow
                captionSection
                if !garments.isEmpty {
                    itemsSection
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(Self.dateTitle(for: post))
        .navigationBarTitleDisplayMode(.inline)
        .compactNavBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { actionsMenu }
        }
        .confirmationDialog(
            String(localized: "look_post_delete_question"),
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "look_post_delete"), role: .destructive) {
                // Pop first: the view must not read a deleted model while it animates out.
                let doomed = post
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    LookPostStore.delete(doomed, context: context)
                }
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        }
        .task(id: post.photoPath) { await loadPhoto() }
        .onAppear {
            captionDraft = post.caption ?? ""
            garments = ModelQueries.fetchGarments(ids: post.garmentIDs, context: context)
        }
        .withLocalAppBackdrop()
    }

    static func dateTitle(for post: LookPost) -> String {
        let date = post.lookDate.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard post.isEvening else { return date }
        return String(format: String(localized: "look_post_evening_date_format"), date)
    }

    // MARK: Parts

    private var photo: some View {
        Color(.systemGray6)
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text(Self.dateTitle(for: post)))
    }

    private var metaRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Label(String(localized: "look_post_only_me"), systemImage: "lock.fill")
            if post.faceHidden {
                Label(String(localized: "look_capture_hide_face"), systemImage: "face.dashed")
            }
            if post.backgroundBlurred {
                Label(String(localized: "look_capture_blur_background"), systemImage: "person.and.background.dotted")
            }
            Spacer(minLength: 0)
            if post.isPinned {
                Image(systemName: "pin.fill")
                    .accessibilityLabel(Text(String(localized: "look_post_pinned")))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var captionSection: some View {
        if isEditingCaption {
            VStack(alignment: .trailing, spacing: DS.Spacing.xs) {
                TextField(String(localized: "look_capture_caption_placeholder"), text: $captionDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($captionFocused)
                    .dsFieldStyle()
                Button(String(localized: "action_save")) {
                    let trimmed = captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    post.caption = trimmed.isEmpty ? nil : trimmed
                    try? context.save()
                    isEditingCaption = false
                }
                .dsSecondaryButton()
            }
        } else {
            Button {
                isEditingCaption = true
                captionFocused = true
            } label: {
                Text(post.caption ?? String(localized: "look_post_add_caption"))
                    .font(post.caption == nil ? .subheadline : .body)
                    .foregroundStyle(post.caption == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        }
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "look_post_items_title"), icon: "tag")
            ForEach(garments) { garment in
                HStack(spacing: DS.Spacing.sm) {
                    DSGarmentThumbnail(garment, size: .small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(garment.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if let brand = garment.brand, !brand.isEmpty {
                            Text(brand)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: DS.Spacing.xs)
                    Toggle(String(localized: "look_post_show_tag"), isOn: tagBinding(for: garment.id))
                        .labelsHidden()
                        .accessibilityLabel(Text(String(format: String(localized: "look_post_show_tag_a11y_format"), garment.name)))
                }
            }
            Text(String(localized: "look_post_tags_footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(DS.Spacing.sm)
        .liquidGlassSurface(cornerRadius: DS.Radius.card)
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                LookPostStore.setPinned(!post.isPinned, for: post, context: context)
            } label: {
                Label(
                    String(localized: post.isPinned ? "look_post_unpin" : "look_post_pin"),
                    systemImage: post.isPinned ? "pin.slash" : "pin"
                )
            }
            if let path = post.photoPath, let url = ImageStore.fileURL(path: path) {
                ShareLink(item: url) {
                    Label(String(localized: "action_share"), systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label(String(localized: "look_post_delete"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(String(localized: "look_post_options")))
    }

    // MARK: Data

    private func tagBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { post.publicTaggedGarmentIDs.contains(id) },
            set: { show in
                if show {
                    if !post.publicTaggedGarmentIDs.contains(id) { post.publicTaggedGarmentIDs.append(id) }
                } else {
                    post.publicTaggedGarmentIDs.removeAll { $0 == id }
                }
                try? context.save()
            }
        )
    }

    private func loadPhoto() async {
        guard let path = LookPostStore.localPhotoPath(for: post) else { return }
        let maxPixel = LookPhotoProcessor.outputSize.height
        let loaded = await Task.detached(priority: .userInitiated) {
            ImageStore.loadThumbnail(path: path, maxPixelSize: maxPixel)
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
