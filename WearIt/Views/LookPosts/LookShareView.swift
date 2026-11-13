import SwiftUI
import SwiftData
import UIKit

/// A draft for one external share. It never publishes a post or changes visibility.
struct LookShareView: View {
    let post: LookPost

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var users: [UserProfile]

    @State private var format: LookShareFormat = .post
    @State private var includeIdentity = false
    @State private var includeCaption = false
    @State private var selectedTagIDs: Set<UUID> = []
    @State private var tags: [Tag] = []
    @State private var photoPath: String?
    @State private var preview: UIImage?
    @State private var renderedRequest: LookShareRenderer.Request?
    @State private var renderFailed = false
    @State private var retry = 0
    @State private var shareImage: ShareImage?
    @State private var didLoad = false

    private struct Tag: Identifiable {
        let id: UUID
        let title: String
    }

    private struct ShareImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private var identity: [String] {
        guard let profile = CurrentUser.activeProfile(from: users, userIdentifier: AuthManager.shared.userIdentifier),
              post.ownerID == nil || post.ownerID == profile.id else { return [] }
        var lines: [String] = []
        let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != "Me", name != String(localized: "profile_default_name") {
            lines.append(name)
        }
        if let username = profile.username, !username.isEmpty { lines.append("@\(username)") }
        return lines
    }

    private var caption: String? {
        let value = post.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private var request: LookShareRenderer.Request? {
        guard let photoPath else { return nil }
        return LookShareRenderer.Request(
            photoPath: photoPath, format: format,
            identity: includeIdentity ? identity : [], caption: includeCaption ? caption : nil,
            tags: tags.filter { selectedTagIDs.contains($0.id) }.map(\.title),
            isRightToLeft: layoutDirection == .rightToLeft,
            subtitle: String(localized: "look_share_card_subtitle"),
            tagsTitle: String(localized: "look_post_items_title")
        )
    }

    private var currentPreview: UIImage? {
        renderedRequest == request ? preview : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    previewSection
                    formatPicker
                    detailsSection
                    if !tags.isEmpty { tagsSection }
                    Text(String(localized: "look_share_footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(DS.Spacing.md)
            }
            .navigationTitle(String(localized: "look_share_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard let currentPreview else { return }
                    shareImage = ShareImage(image: currentPreview)
                } label: {
                    Label(String(localized: "action_share"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .dsPrimaryButton()
                .disabled(currentPreview == nil)
                .padding(DS.Spacing.md)
                .background(DS.Surface.canvas)
            }
            .withLocalAppBackdropPainted()
        }
        .onAppear(perform: loadSource)
        .task(id: RenderKey(request: request, retry: retry)) {
            await renderPreview()
        }
        .sheet(item: $shareImage) { payload in
            LookShareActivitySheet(image: payload.image)
        }
    }

    private var previewSection: some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            previewContent
        }
        .aspectRatio(format.size.width / format.size.height, contentMode: .fit)
        .frame(maxWidth: 380)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var previewContent: some View {
        if let currentPreview {
            Image(uiImage: currentPreview)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(String(localized: "look_share_preview"))
        } else if renderFailed || (didLoad && photoPath == nil) {
            VStack(spacing: DS.Spacing.sm) {
                Label(String(localized: "look_share_failed"), systemImage: "photo")
                    .foregroundStyle(.secondary)
                Button(String(localized: "look_share_retry")) {
                    photoPath = LookPostStore.localPhotoPath(for: post)
                    retry += 1
                }
                .dsSecondaryButton()
            }
            .frame(maxWidth: .infinity)
            .padding(DS.Spacing.md)
        } else {
            ProgressView(String(localized: "look_share_preparing"))
        }
    }

    @ViewBuilder
    private var formatPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            formatChoices
                .pickerStyle(.menu)
                .frame(minHeight: 44)
        } else {
            formatChoices
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
        }
    }

    private var formatChoices: some View {
        Picker(String(localized: "look_share_format"), selection: $format) {
            ForEach(LookShareFormat.allCases) { option in
                Text(option.title).tag(option)
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "look_share_details"), icon: "person.crop.rectangle")
            Toggle(String(localized: "look_share_identity"), isOn: $includeIdentity)
                .disabled(identity.isEmpty)
                .frame(minHeight: 44)
            if identity.isEmpty {
                Text(String(localized: "look_share_identity_missing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if caption != nil {
                Toggle(String(localized: "look_share_caption"), isOn: $includeCaption)
                    .frame(minHeight: 44)
            }
        }
        .padding(DS.Spacing.md)
        .contentSurface()
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "look_share_tags"), icon: "tag")
            ForEach(tags) { tag in
                Toggle(tag.title, isOn: tagBinding(for: tag.id))
                    .frame(minHeight: 44)
            }
            Text(String(localized: "look_share_tags_detail"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(DS.Spacing.md)
        .contentSurface()
    }

    private func tagBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedTagIDs.contains(id) },
            set: { selected in
                if selected { selectedTagIDs.insert(id) }
                else { selectedTagIDs.remove(id) }
            }
        )
    }

    private func loadSource() {
        guard !didLoad else { return }
        photoPath = LookPostStore.localPhotoPath(for: post)
        let byID = Dictionary(ModelQueries.fetchGarments(ids: post.garmentIDs, context: context)
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<UUID> = []
        tags = post.garmentIDs.compactMap { id in
            guard seen.insert(id).inserted, let garment = byID[id] else { return nil }
            // Personal item names, sizes, IDs, prices and wardrobe photos are never exported.
            let type = garment.itemType?.title ?? garment.category.title
            let brand = garment.brand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Tag(id: id, title: brand.isEmpty ? type : "\(type) · \(brand)")
        }
        selectedTagIDs = Set(post.publicTaggedGarmentIDs).intersection(Set(tags.map(\.id)))
        didLoad = true
    }

    private struct RenderKey: Equatable {
        let request: LookShareRenderer.Request?
        let retry: Int
    }

    private func renderPreview() async {
        guard !Task.isCancelled else { return }
        preview = nil
        renderedRequest = nil
        renderFailed = false
        guard let snapshot = request else { return }
        do { try await Task.sleep(for: .milliseconds(180)) }
        catch { return }
        guard !Task.isCancelled else { return }
        let rendered = await LookShareRenderer.shared.render(snapshot)
        guard !Task.isCancelled, request == snapshot else { return }
        preview = rendered
        renderedRequest = snapshot
        renderFailed = rendered == nil
    }
}

private struct LookShareActivitySheet: UIViewControllerRepresentable {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in dismiss() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
